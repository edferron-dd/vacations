"""The Claude tool-use loop for one chat turn."""

import asyncio
from dataclasses import dataclass
from datetime import date
from typing import Any

import anthropic

from tools import TOOLS, VacationsApi

MAX_STEPS = 10  # model calls per user turn; a booking flow typically needs 2-4

SYSTEM_PROMPT = """You are the booking assistant for Horizon Getaways, a vacation company. Today is {today}.

You help guests find destinations, check availability and prices, book stays, look up or cancel \
reservations, and give weather and packing advice for a booked trip, using the tools provided. Destinations, prices, availability and confirmation codes come \
only from tool results - never invent them.

Booking: before calling create_reservation, make sure you know the destination, check-in and check-out \
dates, number of guests, the guest's full name and email. Check availability first, then summarize the \
booking with its total price and ask the guest to confirm. Only book after they clearly say yes.

Cancelling: looking up or cancelling a reservation needs the confirmation code and the email it was booked \
with. Confirm which reservation will be cancelled and get a clear yes before calling cancel_reservation.

Dates: interpret relative dates ("next weekend", "in March") from today's date; when a month has no year, \
use its next upcoming occurrence. Prices are in USD per night; a stay's total is nights x nightly price.

If a tool returns an error, explain the problem in plain words and suggest a fix (other dates, fewer guests, \
a similar destination). Replies are shown in a small chat window: keep them short and friendly, using brief \
paragraphs or short bullet lists, no tables or headings. Only help with Horizon Getaways travel and bookings."""


@dataclass
class TurnResult:
    reply: str
    bookings_changed: bool


class BookingAgent:
    def __init__(self, client: anthropic.AsyncAnthropic, api: VacationsApi, model: str, effort: str, fallbacks: bool) -> None:
        self._client = client
        self._api = api
        self._model = model
        self._effort = effort
        self._fallbacks = fallbacks

    async def run_turn(self, history: list[dict[str, Any]], user_text: str) -> TurnResult:
        """Appends the turn to `history` (append-only). If the turn fails, history is rolled back to how it was."""
        start = len(history)
        history.append({"role": "user", "content": user_text})
        changed = False
        try:
            for _ in range(MAX_STEPS):
                response = await self._create(history)
                # Stored as plain JSON (not SDK objects) so the history can be persisted; thinking blocks keep their signatures.
                history.append({"role": "assistant", "content": [
                    block.model_dump(mode="json", exclude_none=True) for block in response.content
                ]})

                if response.stop_reason == "refusal":
                    # Drop the declined turn so the conversation can continue normally.
                    del history[start:]
                    return TurnResult("Sorry, I can't help with that. I can search destinations, check availability, "
                                      "and make or manage bookings.", changed)
                if response.stop_reason == "pause_turn":
                    continue
                if response.stop_reason != "tool_use":
                    text = _text(response.content)
                    if response.stop_reason == "max_tokens":
                        text += "\n\n(My reply was cut short - ask me to continue.)"
                    return TurnResult(text or "Done.", changed)

                calls = [block for block in response.content if block.type == "tool_use"]
                outcomes = await asyncio.gather(*(self._api.run(call.name, dict(call.input)) for call in calls))
                changed = changed or any(o.changed_bookings for o in outcomes)
                # All results for one assistant message go back together in a single user message.
                history.append({"role": "user", "content": [
                    {"type": "tool_result", "tool_use_id": call.id, "content": o.content, "is_error": o.is_error}
                    for call, o in zip(calls, outcomes)
                ]})

            return TurnResult("I'm having trouble finishing that request - could you rephrase or break it into steps?", changed)
        except BaseException:
            del history[start:]
            raise

    async def _create(self, history: list[dict[str, Any]]):
        extra: dict[str, Any] = {}
        if self._fallbacks:
            # On a safety-classifier decline, the API retries on Anthropic's recommended fallback model.
            extra = {"betas": ["server-side-fallback-2026-07-01"], "fallbacks": "default"}
        return await self._client.beta.messages.create(
            model=self._model,
            max_tokens=16000,
            system=SYSTEM_PROMPT.format(today=date.today().isoformat()),
            tools=TOOLS,
            messages=history,
            thinking={"type": "adaptive"},
            output_config={"effort": self._effort},
            cache_control={"type": "ephemeral"},
            **extra,
        )


def _text(content) -> str:
    return "\n\n".join(block.text for block in content if block.type == "text").strip()
