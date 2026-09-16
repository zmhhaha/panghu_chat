"""Render deployment resources without touching the cluster or reading secrets."""
from pathlib import Path
import sys
import yaml

cfg = yaml.safe_load(Path(sys.argv[1]).read_text(encoding="utf-8"))
for key in ("image", "oauth_image", "hostname", "owner_email", "oidc_issuer", "storage_class", "node_hostname"):
    if not cfg.get(key) or "REPLACE" in cfg[key]:
        raise SystemExit(f"Set {key} in deployment.local.yaml")
for key in ("image", "oauth_image"):
    if "@sha256:" not in cfg[key]:
        raise SystemExit(f"{key} must be pinned by digest")
ns = "hermes"
docs = []


def resource(kind, name, **fields):
    api = {"Deployment": "apps/v1", "CronJob": "batch/v1", "NetworkPolicy": "networking.k8s.io/v1"}.get(kind, "v1")
    obj = {"apiVersion": api, "kind": kind, "metadata": {"name": name, "namespace": ns}, **fields}
    docs.append(obj)
    return obj


docs.append({"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": ns}})
resource("ServiceAccount", "hermes", automountServiceAccountToken=False)
for name, size in (("hermes-web", cfg.get("web_storage", "10Gi")), ("hermes-reports", cfg.get("report_storage", "10Gi"))):
    resource("PersistentVolumeClaim", name, spec={"accessModes": ["ReadWriteOnce"], "storageClassName": cfg["storage_class"], "resources": {"requests": {"storage": size}}})
resource("ConfigMap", "hermes-owner", data={"emails": cfg["owner_email"] + "\n"})
sources = (Path(__file__).parents[1] / "config/sources.yaml").read_text(encoding="utf-8")
resource("ConfigMap", "hermes-sources", data={"sources.yaml": sources})
security = {"runAsNonRoot": True, "runAsUser": 10000, "runAsGroup": 10000,
            "allowPrivilegeEscalation": False, "capabilities": {"drop": ["ALL"]}, "seccompProfile": {"type": "RuntimeDefault"}}


def pod(role):
    return {"serviceAccountName": "hermes", "automountServiceAccountToken": False,
            "nodeSelector": {"kubernetes.io/arch": "arm64", "kubernetes.io/hostname": cfg["node_hostname"]},
            "securityContext": {"fsGroup": 10000, "fsGroupChangePolicy": "OnRootMismatch"},
            "terminationGracePeriodSeconds": 45, "containers": [], "volumes": []}


def container(name, memory="1Gi"):
    return {"name": name, "image": cfg["image"], "imagePullPolicy": "IfNotPresent",
            "resources": {"requests": {"cpu": "100m", "memory": "256Mi"}, "limits": {"cpu": "1", "memory": memory, "ephemeral-storage": "2Gi"}}}


web = pod("web")
dashboard = container("hermes", "2Gi")
# Upstream s6 initializes ownership as root then drops to UID 10000.
# Do not falsely claim compatibility with Pod Security restricted.
dashboard.update(args=["dashboard", "--host", "127.0.0.1", "--no-open"],
    env=[{"name": "HERMES_UID", "value": "10000"}, {"name": "HERMES_GID", "value": "10000"}, {"name": "TZ", "value": "Asia/Shanghai"}],
    envFrom=[{"secretRef": {"name": "hermes-model"}}],
    volumeMounts=[{"name": "home", "mountPath": "/opt/data"}],
    securityContext={"allowPrivilegeEscalation": False, "capabilities": {"drop": ["ALL"], "add": ["CHOWN", "FOWNER", "DAC_OVERRIDE", "SETUID", "SETGID"]}, "seccompProfile": {"type": "RuntimeDefault"}})
dashboard["readinessProbe"] = {"exec": {"command": ["/opt/hermes/.venv/bin/python", "-c", "import socket; socket.create_connection(('127.0.0.1',9119),2).close()"]}, "periodSeconds": 15, "timeoutSeconds": 5}
dashboard["startupProbe"] = {"exec": dashboard["readinessProbe"]["exec"], "periodSeconds": 10, "timeoutSeconds": 5, "failureThreshold": 60}
repo = Path(__file__).resolve().parents[3]
proxy = yaml.safe_load((repo / "oauth/k8s/hermes-proxy-container.yaml").read_text(encoding="utf-8"))
proxy["image"] = cfg["oauth_image"]
proxy["args"] = [arg.replace("__OIDC_ISSUER__", cfg["oidc_issuer"])
                 .replace("__HOSTNAME__", cfg["hostname"]) for arg in proxy["args"]]
web["containers"] = [dashboard, proxy]
web["volumes"] = [{"name": "home", "persistentVolumeClaim": {"claimName": "hermes-web"}}, {"name": "owner", "configMap": {"name": "hermes-owner"}}]
resource("Deployment", "hermes-web", spec={"replicas": 1, "strategy": {"type": "Recreate"},
    "selector": {"matchLabels": {"app": "hermes-web"}}, "template": {"metadata": {"labels": {"app": "hermes-web", "role": "web"}}, "spec": web}})
resource("Service", "hermes-web", spec={"selector": {"app": "hermes-web"}, "ports": [{"port": 4180, "targetPort": "http"}]})

for action, schedule, deadline in (("collect", "15 */3 * * *", 900), ("report", "0 20 * * *", 1200), ("publish", "*/10 20-23 * * *", 300)):
    spec = pod(action)
    spec["restartPolicy"] = "Never"
    c = container(action, "2Gi" if action == "report" else "512Mi")
    c.update(command=["/opt/hermes/.venv/bin/python", "-m", "app.pipeline", action], securityContext=security,
             env=[{"name": "REPORT_HOME", "value": "/reports"}, {"name": "HERMES_HOME", "value": "/reports/agent"},
                  {"name": "SOURCE_CONFIG", "value": "/sources/sources.yaml"}, {"name": "TZ", "value": "Asia/Shanghai"}],
             volumeMounts=[{"name": "reports", "mountPath": "/reports"}, {"name": "sources", "mountPath": "/sources", "readOnly": True}])
    spec["volumes"] = [{"name": "reports", "persistentVolumeClaim": {"claimName": "hermes-reports"}}, {"name": "sources", "configMap": {"name": "hermes-sources"}}]
    if action == "report":
        c["envFrom"] = [{"secretRef": {"name": "hermes-model"}}]
        # Seed a separate research profile; never share the private chat history.
        init = container("seed-config")
        init.update(securityContext=security, command=["/opt/hermes/.venv/bin/python", "-c",
            "from pathlib import Path; import shutil; p=Path('/reports/agent'); p.mkdir(exist_ok=True); shutil.copyfile('/seed/config.yaml',p/'config.yaml')"],
            volumeMounts=[{"name": "reports", "mountPath": "/reports"}, {"name": "seed", "mountPath": "/seed", "readOnly": True}])
        spec["volumes"].append({"name": "seed", "secret": {"secretName": "hermes-research-config"}})
        spec["initContainers"] = [init]
    if action == "publish":
        spec["volumes"].append({"name": "token", "secret": {"secretName": "hermes-hublog", "defaultMode": 288}})
        c["volumeMounts"].append({"name": "token", "mountPath": "/credentials", "readOnly": True})
    spec["containers"] = [c]
    resource("CronJob", "hermes-" + action, spec={"schedule": schedule, "timeZone": "Asia/Shanghai",
        "suspend": True, "concurrencyPolicy": "Forbid", "startingDeadlineSeconds": 600,
        "successfulJobsHistoryLimit": 2, "failedJobsHistoryLimit": 3,
        "jobTemplate": {"spec": {"backoffLimit": 0, "activeDeadlineSeconds": deadline, "ttlSecondsAfterFinished": 86400,
            "template": {"metadata": {"labels": {"app": "hermes-" + action, "role": action}}, "spec": spec}}}})

dns = {"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "kube-system"}}, "podSelector": {"matchLabels": {"k8s-app": "kube-dns"}}}], "ports": [{"protocol": "UDP", "port": 53}, {"protocol": "TCP", "port": 53}]}
public = {"to": [{"ipBlock": {"cidr": "0.0.0.0/0", "except": ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8", "169.254.0.0/16", "100.64.0.0/10", "0.0.0.0/8", "224.0.0.0/4", "240.0.0.0/4"]}}], "ports": [{"protocol": "TCP", "port": 443}]}
resource("NetworkPolicy", "default-deny", spec={"podSelector": {}, "policyTypes": ["Ingress", "Egress"]})
resource("NetworkPolicy", "research-egress", spec={"podSelector": {"matchExpressions": [{"key": "role", "operator": "In", "values": ["web", "collect", "report"]}]}, "policyTypes": ["Egress"], "egress": [dns, public]})
resource("NetworkPolicy", "hublog-publisher", spec={"podSelector": {"matchLabels": {"role": "publish"}}, "policyTypes": ["Egress"], "egress": [dns, {"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "hublog"}}, "podSelector": {"matchLabels": {"app": "hublog-api"}}}], "ports": [{"protocol": "TCP", "port": 8080}]}]})
resource("NetworkPolicy", "tunnel-ingress", spec={"podSelector": {"matchLabels": {"role": "web"}}, "policyTypes": ["Ingress"], "ingress": [{"from": [{"namespaceSelector": {}, "podSelector": {"matchLabels": {"hermes-ingress": "true"}}}], "ports": [{"protocol": "TCP", "port": 4180}]}]})
print(yaml.safe_dump_all(docs, sort_keys=False))
