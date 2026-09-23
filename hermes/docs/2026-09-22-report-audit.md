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

No report was regenerated or edited and no additional model call was made.
The revised prompt still needs acceptance against the next real report.
Native extraction checks addresses before choosing a provider; changing provider
alone does not fix the Fake-IP SSRF rejection. Keep SSRF checks intact and resolve
public-name DNS/proxy behavior separately, without granting internal access.
Provider reliability, spending caps, full security boundaries and quiesced
backup/restore remain open acceptance items.
