# Native report evidence audit (2026-09-22)

## Result

Scheduling and public delivery work. Report quality acceptance remains open.
The report job is `7b7fd2f1b117`; publication is `1fb99c5df20f`.
The first report completed at 20:01:39 +08:00. Publication succeeded at
20:55:42 after the owner repaired the Hublog service-token registration.
Receipt post ID: `944262ba-44a1-4e7e-9b11-eb869c79e2a5`.

## Evidence and limitations

The report session `cron_7b7fd2f1b117_20260922_200016` recorded 19 searches
and one extraction. Five searches failed with keyless Firecrawl HTTP 403;
one search returned no results. The only extraction was rejected as targeting
a private/internal address. Some successful searches returned substantial text,
so unsuccessful extraction does not mean that every report claim was invented.

Nevertheless, claims of having directly checked official documents are not
supported by these tool records. Older papers were presented as current
hotspots; model-release lists relied on aggregators; employment coverage lacked
actual employer posting samples. Syndicated reports are not independent sources.

A separate operator HTTP sample found arXiv `2608.24053` available with title
"WeMM-Embedding: WeChat Multi-Modal Embedding Technical Report". The cited Fed
projection page returned HTTP 403 and the Hugging Face daily list failed TLS.
These failures establish unavailability in this check, not factual falsehood.
This operator check does not establish native extraction-tool availability.

The keyless search ring was also inspected. Firecrawl was repeatedly returning
HTTP 403 because no Firecrawl credential is configured. Its tier is now set to
`paid`, which excludes it from the anonymous fallback ring instead of retrying
the known failing endpoint. The setting is in `/opt/data/config.yaml`, with the
previous file backed up as `/opt/data/config.yaml.before-firecrawl-disable`.
Hermes web was restarted successfully after the change. Other providers remain
subject to their own availability and should be checked by the next report.

## Changes applied

Strengthened `config/native-report-prompt.txt` to distinguish original documents,
indexed excerpts and secondary sources; require dated specific citations; reserve
calls for verification; avoid unsupported precision and speculative release lists;
and seek mainland/overseas employer samples with explicit sampling limitations.
Partial coverage must be disclosed, and insufficient research must fail visibly.
The 20-call instruction is not an enforced monetary cap.

Updated the existing live job through `cron.jobs.update_job`, changing only its
prompt. Schedule, model, lifecycle and next execution were checked unchanged.
Old prompt: `/opt/data/cron/prompt-backups/2026-09-22-evidence-audit.txt`.
New prompt SHA-256:
`b437100ad5da929d453fa4d4fd96eff35290518dd80cfbe7edbabe62bc820c88`.
No rebuild or restart is needed for this live update. Rebuilding alone would not
update an existing task because the installer deliberately preserves user edits.

## Verification and remaining work

Called production delivery with HTTP connection constructors mocked to fail:
the existing receipt skipped delivery, made no HTTP connection, and left payload
and receipt hashes unchanged. This verifies receipt-based skipping, not Hublog's
crash-between-publication-and-receipt idempotency behavior.

That case was then exercised against the real Hublog API using the already
published 2026-09-22 payload and the exact key
`hermes-daily:2026-09-22:v1`. Hublog returned HTTP 201 with the existing post ID
`944262ba-44a1-4e7e-9b11-eb869c79e2a5`, so the retry did not create a duplicate.
The Hublog implementation also rejects reuse of a key with different content.

No report was regenerated or edited and no additional model call was made.
The revised prompt still needs acceptance against the next real report.
Native extraction checks addresses before choosing a provider. The runtime config
now recognizes the cluster proxy's public-name Fake-IP range
`198.18.0.0/15` through `security.fake_ip_ranges`, while
`security.allow_private_urls` remains false. The previous config was backed up at
`/opt/data/config.yaml.before-fake-ip-fix`, and Hermes web was restarted. This
allows the proxy sentinel to be dialed without granting RFC1918, loopback or
metadata access. Keyless Firecrawl 403 remains a separate provider limitation.
Provider reliability, spending caps, full security boundaries and quiesced
backup/restore remain open acceptance items.

## Authentication audit (2026-09-23)

The live OAuth2 Proxy configuration was checked without exposing secrets. OIDC
uses `https://auth.panghuer.top`, the owner email file is mounted read-only, and
the current allowlist contains only the intended owner address. Cookies use the
`__Host-` prefix, Secure, SameSite=Lax, an eight-hour expiry and one-hour refresh.
Per-request CSRF cookies and WebSocket proxying are enabled; the tunnel policy
admits only the Cloudflare tunnel workload to port 4180.

MFA enforcement at Casdoor and immediate invalidation of an already issued
session after allowlist revocation were not asserted from Hermes configuration.
They require an identity-provider/session test and remain open. No credentials,
cookies or existing sessions were changed during this audit.

## Backup drill (2026-09-23)

Application-level archives were created on the master under the mode-0700
directory `/var/backups/hermes/`:

- `hermes-web-20260923-170016.tar.gz` (413 MiB)
- `hermes-reports-20260923-170016.tar.gz` (17 KiB)

Both archives were extracted to `verify-20260923-170016/`; 23,634 files were
present, including native jobs, report payload and publication receipt. Runtime
sockets were excluded. SHA-256:

- web: `16ad818e7c83a8b9304fddb84f105c3c09e3ca733c000dd955d44b96e2de5966`
- reports: `ea562679adfae084c5de4413870728c8b02b67b247a8818752daf3fb82391073`

This is an online archive/extraction check, not a proven quiesced recovery.
A subsequent attempt to quiesce both Deployments was interrupted before a
backup helper started; both Deployments were restored to one replica and
verified Running/Ready (web 2/2, publisher 1/1). No production PVC was replaced.
Consistent SQLite recovery and a full isolated PVC restore remain open.
