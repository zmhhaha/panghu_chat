import asyncio
from pathlib import Path

import asyncpg

from .config import get_settings


async def main() -> None:
    settings = get_settings()
    dsn = settings.database_url.replace("postgresql+asyncpg://", "postgresql://", 1)
    migration_dir = Path(__file__).parents[1] / "migrations"
    conn = await asyncpg.connect(dsn)
    try:
        await conn.execute("SELECT pg_advisory_lock(hashtext('hublog_schema_migrations'))")
        await conn.execute(
            "CREATE TABLE IF NOT EXISTS hublog_schema_migrations "
            "(version text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())"
        )
        for path in sorted(migration_dir.glob("*.sql")):
            applied = await conn.fetchval("SELECT 1 FROM hublog_schema_migrations WHERE version = $1", path.name)
            if applied:
                continue
            async with conn.transaction():
                await conn.execute(path.read_text(encoding="utf-8"))
                await conn.execute("INSERT INTO hublog_schema_migrations(version) VALUES($1)", path.name)
    finally:
        await conn.execute("SELECT pg_advisory_unlock(hashtext('hublog_schema_migrations'))")
        await conn.close()


if __name__ == "__main__":
    asyncio.run(main())
