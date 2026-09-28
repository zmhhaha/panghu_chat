# GitHub SSH

See [shared setup instructions](../../dsh/docs/github-ssh.md) for key generation,
GitHub authorization, verified known_hosts and Vault import commands.

Hermes uses `secret/hermes/github` and `hermes/hermes-github-ssh`; its identity is
independent of DSH. Only the Hermes execution container mounts the key. The
publisher never receives it. Rebuild the Hermes image and deploy before using
SSH remotes. This feature is optional and does not grant access until GitHub
authorizes the public key and the Vault secret is populated.
