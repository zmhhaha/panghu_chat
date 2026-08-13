import json
from datetime import datetime, timezone

from redis.asyncio import Redis

from .config import get_settings


def get_redis() -> Redis:
    return Redis.from_url(get_settings().redis_url, decode_responses=True)


async def ping_redis() -> None:
    client = get_redis()
    try:
        await client.ping()
    finally:
        await client.aclose()


async def publish_event(client: Redis, stream: str, event: dict) -> str:
    return await client.xadd(stream, {"event": json.dumps(event, separators=(",", ":"), default=str), "published_at": datetime.now(timezone.utc).isoformat()})
