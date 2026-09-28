# GitHub SSH for DSH and Hermes

This optional feature grants Git write access, superseding the public-clone-only
policy only for repositories explicitly authorized in GitHub. No credentials are
committed. No production configuration is changed by editing these files.

Generate two separate unencrypted Ed25519 keys in a private host directory
outside the checkout (do not overwrite existing keys). For example:

```bash
install -d -m 700 /root/agent-github
ssh-keygen -t ed25519 -N '' -C dsh-github -f /root/agent-github/dsh
ssh-keygen -t ed25519 -N '' -C hermes-github -f /root/agent-github/hermes
```

Upload ONLY each `.pub` file to GitHub. For a single repository, use a deploy key
with write access if needed. For several repositories, use a dedicated machine
account with access only to those repositories. Configure protected branches in
GitHub; the container configuration does not prevent force pushes or main-branch
pushes. All DSH projects using the current runner template share the DSH Git key.

Create `/root/agent-github/known_hosts` with verified host keys for
`[ssh.github.com]:443`. Obtain candidate keys with `ssh-keyscan -p 443
ssh.github.com`, compare their SHA256 fingerprints with GitHub's published SSH
fingerprints via a trusted channel, then save only verified entries. Scanning
alone does not establish trust. Do not turn off host-key checking.

Load each key into its own Vault path; commands run from the cluster host:

```bash
kubectl -n vault exec -i vault-0 -- vault kv put secret/dsh/github id_ed25519=- < /root/agent-github/dsh
kubectl -n vault exec -i vault-0 -- vault kv patch secret/dsh/github known_hosts=- < /root/agent-github/known_hosts
kubectl -n vault exec -i vault-0 -- vault kv put secret/hermes/github id_ed25519=- < /root/agent-github/hermes
kubectl -n vault exec -i vault-0 -- vault kv patch secret/hermes/github known_hosts=- < /root/agent-github/known_hosts
kubectl apply -f vault/inventory/dsh-github-externalsecret.yaml
kubectl apply -f vault/inventory/hermes-github-externalsecret.yaml
kubectl -n dsh-runners wait --for=condition=Ready externalsecret/dsh-github-ssh --timeout=180s
kubectl -n hermes wait --for=condition=Ready externalsecret/hermes-github-ssh --timeout=180s
```

The initial `put` replaces that dedicated path. For later key rotation use
`vault kv patch ... id_ed25519=-` to preserve known_hosts. Check the existing
vault-backend policy permits these paths; extend only these paths if needed.

Rebuild both images using their existing build scripts. Re-provision the DSH
project runner and restart DSH web to reconnect its SSH transport. Deploy Hermes
using its existing deploy script. Merely updating a ConfigMap cannot install the
new wrapper in an old image. These two ExternalSecret files are deliberately
opt-in and not added to mandatory deployment readiness checks.

Use SSH remotes such as `git@github.com:OWNER/REPO.git`. HTTPS remotes do not use
this key. Git invokes `/usr/local/bin/github-ssh`, which connects to GitHub's
official SSH endpoint on TCP 443, pins known_hosts, disables agent forwarding
and interactive authentication, and selects only the mounted identity. This is
a GitHub-only default; override deliberately for other Git hosts. Internal DSH
Web-to-runner SSH uses its original configuration and transport credentials.

DSH mounts the Secret only in runner; Hermes mounts it only in the main execution
container, not publisher or oauth2-proxy. Secret mode 0440 and fsGroup 10000 allow
the runtime user to read it. Each invocation makes a user-owned mode-0600 copy
in /tmp and removes it on normal exit/signals. SIGKILL can leave a temporary copy
until the Pod is replaced. Secret updates are read on the next invocation after
Kubernetes propagation; no subPath mount or persistent workspace key is used.

Missing credentials do not prevent service startup; SSH Git operations fail
explicitly. The executing agent can read its Git private key: read-only mounts
prevent modification, not exfiltration. Never mount the host's entire .ssh.

After deployment, verify `git ls-remote git@github.com:OWNER/REPO.git HEAD` from
each execution environment, then push only to a designated test branch. These
live GitHub permission and push checks have not been performed by this change.
