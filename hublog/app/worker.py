import asyncio
import logging
from datetime import datetime, timezone

from sqlalchemy import select

from .config import get_settings
from .db import SessionLocal
from .models import OutboxEvent
from .redis_bus import get_redis, publish_event

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("hublog.worker")
settings = get_settings()


async def publish_pending() -> int:
    redis = get_redis()
    count = 0
    try:
        async with SessionLocal() as db:
            rows = (await db.scalars(select(OutboxEvent).where(OutboxEvent.status == "pending").order_by(OutboxEvent.created_at).limit(settings.outbox_batch_size).with_for_update(skip_locked=True))).all()
            for event in rows:
                body = {"event_id": str(event.id), "event_type": event.event_type, "aggregate_id": str(event.aggregate_id), "version": event.aggregate_version, "payload": event.payload, "created_at": event.created_at}
                try:
                    await publish_event(redis, settings.redis_stream, body)
                    event.status = "published"
                    event.published_at = datetime.now(timezone.utc)
                    event.last_error = None
                    count += 1
                except Exception as exc:
                    event.retry_count += 1
                    event.last_error = str(exc)[:1000]
                    if event.retry_count >= 10:
                        event.status = "failed"
                    logger.exception("failed to publish outbox event %s", event.id)
            await db.commit()
    finally:
        await redis.aclose()
    return count


async def main() -> None:
    while True:
        published = await publish_pending()
        if published:
            logger.info("published %d events", published)
        await asyncio.sleep(settings.outbox_poll_seconds)


if __name__ == "__main__":
    asyncio.run(main())
