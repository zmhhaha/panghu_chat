#!/usr/bin/env python3
"""Generate a Hublog service token and its hash-only Vault entry."""

import argparse
import hashlib
import json
import secrets


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", required=True, help="stable bot name, for example github-trending")
    parser.add_argument("--username", required=True, help="Hublog username, letters/numbers/_/- only")
    parser.add_argument("--display-name", required=True)
    parser.add_argument("--expires-at", required=True, help="UTC ISO-8601 timestamp, for example 2026-12-31T00:00:00Z")
    args = parser.parse_args()

    token = secrets.token_urlsafe(48)
    entry = {
        "token_hash": hashlib.sha256(token.encode("utf-8")).hexdigest(),
        "subject": f"service:{args.name}",
        "username": args.username,
        "display_name": args.display_name,
    }
    entry["expires_at"] = args.expires_at

    print("SERVICE_TOKEN=" + token)
    print("HUBLOG_SERVICE_TOKENS entry:")
    print(json.dumps({args.name: entry}, ensure_ascii=False, indent=2))
    print("Store only the JSON entry in Vault; give SERVICE_TOKEN to the bot through its own Secret.")


if __name__ == "__main__":
    main()
