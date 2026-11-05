"""Horizon Getaways chat assistant: a FastAPI service that IIS reverse-proxies under /chat/.

Run locally:  uvicorn app:app --host 127.0.0.1 --port 8001 --reload
"""

import asyncio
import logging
import os
import re
import uuid
from contextlib import asynccontextmanager
from typing import Any

import anthropic
import oracledb
from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

from agent import BookingAgent
from store import ChatStore
from tools import VacationsApi

load_dotenv()
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("chatbot")

MODEL = os.getenv("CLAUDE_MODEL", "claude-opus-5-5")
EFFORT = os.getenv("CLAUDE_EFFORT", "medium")
FALLBACKS = os.getenv("CLAUDE_FALLBACKS", "default").lower() != "off"
API_URL = os.getenv("VACATIONS_API_URL", "http://127.0.0.1")
RETENTION_DAYS = int(os.getenv("CHAT_RETENTION_DAYS", "30"))
SESSION_ID = re.compile(r"^[0-9a-f]{32}$")

# Serializes turns within one conversation (single uvicorn worker); history itself lives in Oracle.
locks: dict[str, asyncio.Lock] = {}
state: dict[str, Any] = {}


@asynccontextmanager
async def lifespan(_: FastAPI):
    api = VacationsApi(API_URL)
    client = anthropic.AsyncAnthropic()  # reads ANTHROPIC_API_KEY from the environment / .env
    store = ChatStore(os.environ["ORACLE_USER"], os.environ["ORACLE_PASSWORD"], os.environ["ORACLE_DSN"])
    state["agent"] = BookingAgent(client, api, MODEL, EFFORT, FALLBACKS)
    state["store"] = store
    try:
        log.info("Purged %d chat sessions older than %d days", await store.purge_older_than(RETENTION_DAYS), RETENTION_DAYS)
    except oracledb.Error:
        log.exception("Could not reach Oracle at startup; chat will fail until it is available")
    log.info("Chatbot ready: model=%s effort=%s fallbacks=%s api=%s", MODEL, EFFORT, FALLBACKS, API_URL)
    yield
    await api.aclose()
    await client.close()
    await store.aclose()


app = FastAPI(title="Horizon Getaways assistant", lifespan=lifespan, docs_url="/chat/docs", openapi_url="/chat/openapi.json")


class MessageRequest(BaseModel):
    session_id: str | None = None
    message: str = Field(min_length=1, max_length=4000)


class MessageResponse(BaseModel):
    session_id: str
    reply: str
    bookings_changed: bool


class ResetRequest(BaseModel):
    session_id: str


def _lock(session_id: str) -> asyncio.Lock:
    if len(locks) > 1000:  # drop idle locks so the dict doesn't grow forever
        for sid in [sid for sid, lock in locks.items() if not lock.locked()]:
            del locks[sid]
    return locks.setdefault(session_id, asyncio.Lock())


@app.get("/chat/health")
async def health() -> dict[str, Any]:
    try:
        sessions = await state["store"].count()
    except oracledb.Error:
        log.exception("Health check could not reach Oracle")
        raise HTTPException(503, "Chat history database unavailable")
    return {"status": "ok", "model": MODEL, "sessions": sessions}


@app.post("/chat/api/message", response_model=MessageResponse)
async def message(request: MessageRequest) -> MessageResponse:
    session_id = request.session_id if request.session_id and SESSION_ID.match(request.session_id) else uuid.uuid4().hex
    agent: BookingAgent = state["agent"]
    store: ChatStore = state["store"]
    async with _lock(session_id):  # one turn at a time per conversation
        try:
            history = await store.load(session_id) or []
            result = await agent.run_turn(history, request.message.strip())
            await store.save(session_id, history)
        except oracledb.Error:
            log.exception("Chat history database error")
            raise HTTPException(503, "The assistant can't load this conversation right now. Please try again shortly.")
        except anthropic.AuthenticationError:
            log.exception("Anthropic authentication failed")
            raise HTTPException(500, "The assistant isn't configured correctly (check ANTHROPIC_API_KEY).")
        except anthropic.RateLimitError:
            raise HTTPException(429, "The assistant is busy right now - please try again in a moment.")
        except anthropic.APIStatusError as error:
            log.exception("Claude API error %s", error.status_code)
            raise HTTPException(502, "The assistant hit an error talking to Claude. Please try again.")
        except anthropic.APIConnectionError:
            log.exception("Could not reach the Claude API")
            raise HTTPException(503, "The assistant can't reach Claude right now. Please try again shortly.")
    return MessageResponse(session_id=session_id, reply=result.reply, bookings_changed=result.bookings_changed)


@app.get("/chat/api/history/{session_id}")
async def history(session_id: str) -> dict[str, list[dict[str, str]]]:
    """The visible transcript (user messages and assistant text, no tool calls) so the UI can restore it."""
    if not SESSION_ID.match(session_id):
        raise HTTPException(404, "Unknown session")
    try:
        stored = await state["store"].load(session_id)
    except oracledb.Error:
        log.exception("Chat history database error")
        raise HTTPException(503, "Chat history database unavailable")
    if stored is None:
        raise HTTPException(404, "Unknown session")
    messages = []
    for turn in stored:
        if turn["role"] == "user" and isinstance(turn["content"], str):
            messages.append({"role": "user", "text": turn["content"]})
        elif turn["role"] == "assistant":
            text = "\n\n".join(b["text"] for b in turn["content"] if b.get("type") == "text").strip()
            if text:
                messages.append({"role": "assistant", "text": text})
    return {"messages": messages}


@app.post("/chat/api/reset")
async def reset(request: ResetRequest) -> dict[str, bool]:
    try:
        return {"reset": await state["store"].delete(request.session_id)}
    except oracledb.Error:
        log.exception("Chat history database error")
        raise HTTPException(503, "Chat history database unavailable")
