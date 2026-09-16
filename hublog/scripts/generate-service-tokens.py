#!/usr/bin/env python3
"""Generate one-time credentials for Panghu content agents."""

import argparse
import hashlib
import json
import secrets


BOT_DEFINITIONS = (
    ("github-trending", "github_trending_bot", "GitHub trending bot"),
    ("international-news", "international_news_bot", "International news bot"),
    ("finance-news", "finance_news_bot", "Finance news bot"),
    ("meme-collector", "meme_collector_bot", "Meme collector bot"),
    ("programmer-jobs", "programmer_jobs_bot", "Programmer jobs bot"),
    # llm-service 的每日防护日报（生产者见 panghu_agent/content_agents/llm_guard_report_agent/）
    ("llm-guard-report", "llm_guard_report_bot", "LLM 防护日报"),
)
HERMES_DEFINITIONS = (("hermes", "hermes_bot", "Hermes 日报"),)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--group", choices=["content-agents", "hermes"], default="content-agents")
    parser.add_argument(
        "--expires-at",
        required=True,
        help="UTC ISO-8601 timestamp, for example 2027-02-20T00:00:00Z",
    )
    parser.add_argument(
        "--bot",
        choices=[name for name, _, _ in BOT_DEFINITIONS + HERMES_DEFINITIONS],
        help="Generate a token for only one bot. Use this when adding a bot to an existing token envelope.",
    )
    args = parser.parse_args()
    group_definitions = HERMES_DEFINITIONS if args.group == "hermes" else BOT_DEFINITIONS
    if args.bot and args.bot not in {name for name, _, _ in group_definitions}:
        parser.error("--bot must belong to the selected --group")

    hash_entries: dict[str, dict[str, str]] = {}
    raw_entries: dict[str, dict[str, str]] = {}
    print("Generated service tokens. Store raw values only in Vault/Secret, never in Git:")
    definitions = [definition for definition in group_definitions if not args.bot or definition[0] == args.bot]
    for name, username, display_name in definitions:
        token = secrets.token_urlsafe(48)
        metadata = {
            "subject": f"service:{name}",
            "username": username,
            "display_name": display_name,
            "expires_at": args.expires_at,
        }
        hash_entries[name] = {
            "token_hash": hashlib.sha256(token.encode("utf-8")).hexdigest(),
            **metadata,
        }
        raw_entries[name] = {"token": token, **metadata}
        print(f"SERVICE_TOKEN_{name.upper().replace('-', '_')}={token}")

    hash_json = json.dumps(hash_entries, ensure_ascii=False, separators=(",", ":"))
    raw_json = json.dumps(raw_entries, ensure_ascii=False, separators=(",", ":"))

    print("\nHUBLOG_SERVICE_TOKENS JSON for Hublog (hash-only; store in secret/hublog/auth):")
    print(hash_json)
    print(f"\nHUBLOG_SERVICE_TOKENS JSON for {args.group} (raw; store in secret/{args.group}/auth):")
    print(raw_json)
    print("\nVault commands:")
    print("Existing Hublog configuration: merge the generated entries into the existing JSON first.")
    print("The put command replaces the field; use the FULL merged JSON to preserve other bots.")
    print("kubectl -n vault exec vault-0 -- vault kv put secret/hublog/auth \\")
    print("  HUBLOG_SERVICE_TOKENS='<paste the hash-only JSON above>'")
    print(f"kubectl -n vault exec vault-0 -- vault kv put secret/{args.group}/auth \\")
    print("  HUBLOG_SERVICE_TOKENS='<paste the raw-token JSON above>'")


if __name__ == "__main__":
    main()
