# GitHub SSH

See [shared setup instructions](../../dsh/docs/github-ssh.md) for key generation,
GitHub authorization, verified known_hosts and Vault import commands.

For `known_hosts: No such file or directory` followed by an ExternalSecret
timeout, follow the shared guide's
[recovery commands](../../dsh/docs/github-ssh.md#recover-from-missing-known_hosts--externalsecret-timeout).
They preserve existing private keys, patch the verified host keys, and force
both ExternalSecrets to synchronize. The initial setup and recovery commands
run on the cluster host; manifest paths are relative to the repository root.

Hermes uses `secret/hermes/github` and `hermes/hermes-github-ssh`; its identity is
independent of DSH. Only the Hermes execution container mounts the key. The
publisher never receives it. Rebuild the Hermes image and deploy before using
SSH remotes. This feature is optional and does not grant access until GitHub
authorizes the public key and the Vault secret is populated.
