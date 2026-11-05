"""Chat history persisted in Oracle (VACATION.CHAT_SESSIONS, created by db/05_chat.sql)."""

import json
from typing import Any

import oracledb

oracledb.defaults.fetch_lobs = False  # return CLOBs as str


class ChatStore:
    def __init__(self, user: str, password: str, dsn: str) -> None:
        self._pool = oracledb.create_pool_async(user=user, password=password, dsn=dsn, min=1, max=4, increment=1)

    async def load(self, session_id: str) -> list[dict[str, Any]] | None:
        async with self._pool.acquire() as conn:
            with conn.cursor() as cur:
                await cur.execute("SELECT history FROM chat_sessions WHERE session_id = :sid", sid=session_id)
                row = await cur.fetchone()
        if not row:
            return None
        # python-oracledb decodes columns with an IS JSON check constraint itself (Oracle 21c+); older setups give str.
        return json.loads(row[0]) if isinstance(row[0], str) else row[0]

    async def save(self, session_id: str, history: list[dict[str, Any]]) -> None:
        async with self._pool.acquire() as conn:
            with conn.cursor() as cur:
                # Update-then-insert rather than MERGE: binding the same large CLOB twice in one statement makes
                # Oracle drop the connection (ORA-03138) once the history outgrows an inline bind.
                payload = json.dumps(history)
                cur.setinputsizes(history=oracledb.DB_TYPE_CLOB)  # history can exceed the 32K VARCHAR2 bind limit
                await cur.execute(
                    "UPDATE chat_sessions SET history = :history, updated_at = SYSTIMESTAMP WHERE session_id = :sid",
                    sid=session_id, history=payload,
                )
                if cur.rowcount == 0:
                    cur.setinputsizes(history=oracledb.DB_TYPE_CLOB)
                    await cur.execute(
                        "INSERT INTO chat_sessions (session_id, history) VALUES (:sid, :history)",
                        sid=session_id, history=payload,
                    )
            await conn.commit()

    async def delete(self, session_id: str) -> bool:
        async with self._pool.acquire() as conn:
            with conn.cursor() as cur:
                await cur.execute("DELETE FROM chat_sessions WHERE session_id = :sid", sid=session_id)
                deleted = cur.rowcount > 0
            await conn.commit()
        return deleted

    async def purge_older_than(self, days: int) -> int:
        async with self._pool.acquire() as conn:
            with conn.cursor() as cur:
                await cur.execute("DELETE FROM chat_sessions WHERE updated_at < SYSTIMESTAMP - NUMTODSINTERVAL(:days, 'DAY')", days=days)
                purged = cur.rowcount
            await conn.commit()
        return purged

    async def count(self) -> int:
        async with self._pool.acquire() as conn:
            with conn.cursor() as cur:
                await cur.execute("SELECT COUNT(*) FROM chat_sessions")
                (n,) = await cur.fetchone()
        return n

    async def aclose(self) -> None:
        await self._pool.close()
