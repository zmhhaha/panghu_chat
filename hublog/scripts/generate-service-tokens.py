#!/usr/bin/env python3
"""Generate one-time credentials for all Panghu content agents."""

import argparse
import hashlib
import json
import secrets


BOT_DEFINITIONS = (
    ("github-trending", "github_trending_bot", "GitHub 热门项目机器人"),
    ("international-news", "international_news_bot", "国际新闻机器人"),
    ("meme-collector", "meme_collector_bot", "热梗收集机器人"),
)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expires-at", required=True, help="UTC ISO-8601 timestamp, for example 2027-02-20T00:00:00Z")
    args = parser.parse_args()

    vault_entries = {}
    print("Generated service tokens (store each raw token in its own bot Secret):")
    for name, username, display_name in BOT_DEFINITIONS:
        token = secrets.token_urlsafe(48)
        vault_entries[name] = {
            "token_hash": hashlib.sha256(token.encode("utf-8")).hexdigest(),
            "subject": f"service:{name}",
            "username": username,
            "display_name": display_name,
            "expires_at": args.expires_at,
        }
        print(f"SERVICE_TOKEN_{name.upper().replace('-', '_')}={token}")

    print("\nHUBLOG_SERVICE_TOKENS JSON (store this value in Vault):")
    print(json.dumps(vault_entries, ensure_ascii=False, separators=(",", ":")))
    print("\nVault command template:")
    print("kubectl -n vault exec vault-0 -- vault kv put secret/hublog/auth \\")
    print("  HUBLOG_SERVICE_TOKENS='<paste the JSON above>'")


if __name__ == "__main__":
    main()
