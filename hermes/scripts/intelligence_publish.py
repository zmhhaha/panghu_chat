"""Native no-agent job; credentials stay in the separate publisher workload."""
import urllib.request

request = urllib.request.Request(
    'http://hermes-publisher.hermes.svc.cluster.local:8090/publish',
    data=b'', method='POST')
with urllib.request.urlopen(request, timeout=120) as response:
    print(response.read(4096).decode())
