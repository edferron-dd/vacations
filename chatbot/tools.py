"""Claude tool definitions and their implementations.

Every tool calls the .NET Vacations API over HTTP rather than touching Oracle directly, so
pricing, availability and overbooking rules live in exactly one place.
"""

import json
from dataclasses import dataclass
from typing import Any

import httpx

_DATE = {"type": "string", "description": "Date in YYYY-MM-DD format."}
_EMAIL = {"type": "string", "description": "Email address the reservation was booked with."}
_CODE = {"type": "string", "description": "Confirmation code, e.g. VAC-7KQ2MZ."}

TOOLS: list[dict[str, Any]] = [
    {
        "name": "search_destinations",
        "description": (
            "Search vacation destinations. All filters are optional. 'query' is free text matched word-by-word "
            "against name, country, region, category and description (e.g. 'beach mexico', 'ski'). When check_in "
            "and check_out are both given, each result includes a quote with nights, total price, rooms left and "
            "whether it is available for that stay."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Keywords, e.g. 'japan', 'safari', 'beach'."},
                "category": {
                    "type": "string",
                    "enum": ["BEACH", "ISLAND", "MOUNTAIN", "CITY", "COUNTRYSIDE", "SAFARI"],
                },
                "max_price_per_night": {"type": "number", "description": "Maximum nightly price in USD."},
                "guests": {"type": "integer", "minimum": 1, "description": "Number of travelers."},
                "check_in": _DATE,
                "check_out": _DATE,
                "available_only": {
                    "type": "boolean",
                    "description": "With dates given, return only destinations available for the whole stay.",
                },
            },
            "additionalProperties": False,
        },
    },
    {
        "name": "check_availability",
        "description": "Get the price quote and availability of one destination for specific dates and guest count.",
        "input_schema": {
            "type": "object",
            "properties": {
                "destination_id": {"type": "integer"},
                "check_in": _DATE,
                "check_out": _DATE,
                "guests": {"type": "integer", "minimum": 1},
            },
            "required": ["destination_id", "check_in", "check_out", "guests"],
            "additionalProperties": False,
        },
    },
    {
        "name": "create_reservation",
        "description": (
            "Book a stay. Only call this after the guest has explicitly confirmed the destination, dates, number "
            "of guests, total price, their full name and email. Returns the reservation with its confirmation code."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "destination_id": {"type": "integer"},
                "guest_name": {"type": "string", "description": "Guest's full name."},
                "guest_email": {"type": "string", "description": "Guest's email address."},
                "check_in": _DATE,
                "check_out": _DATE,
                "guests": {"type": "integer", "minimum": 1},
            },
            "required": ["destination_id", "guest_name", "guest_email", "check_in", "check_out", "guests"],
            "additionalProperties": False,
        },
    },
    {
        "name": "get_reservation",
        "description": "Look up one reservation. Requires both the confirmation code and the email used to book.",
        "input_schema": {
            "type": "object",
            "properties": {"confirmation_code": _CODE, "email": _EMAIL},
            "required": ["confirmation_code", "email"],
            "additionalProperties": False,
        },
    },
    {
        "name": "list_reservations",
        "description": "List all reservations (upcoming, past and cancelled) booked with an email address.",
        "input_schema": {
            "type": "object",
            "properties": {"email": _EMAIL},
            "required": ["email"],
            "additionalProperties": False,
        },
    },
    {
        "name": "get_trip_forecast",
        "description": (
            "Weather for each day of a booked stay (check-in through check-out) and a suggested packing list. "
            "Within about two weeks of the trip this is the live forecast (mode 'forecast'); further out it is "
            "typical weather for those dates over the last 3 years (mode 'climate') - say which when you answer. "
            "Requires the confirmation code and the booking email."
        ),
        "input_schema": {
            "type": "object",
            "properties": {"confirmation_code": _CODE, "email": _EMAIL},
            "required": ["confirmation_code", "email"],
            "additionalProperties": False,
        },
    },
    {
        "name": "cancel_reservation",
        "description": (
            "Cancel a reservation before its check-in date. Only call this after the guest has explicitly "
            "confirmed which reservation to cancel. Requires the confirmation code and the booking email."
        ),
        "input_schema": {
            "type": "object",
            "properties": {"confirmation_code": _CODE, "email": _EMAIL},
            "required": ["confirmation_code", "email"],
            "additionalProperties": False,
        },
    },
]

_MUTATING = {"create_reservation", "cancel_reservation"}


@dataclass
class ToolOutcome:
    content: str
    is_error: bool = False
    changed_bookings: bool = False


class VacationsApi:
    def __init__(self, base_url: str) -> None:
        self._http = httpx.AsyncClient(base_url=base_url.rstrip("/"), timeout=30.0)

    async def aclose(self) -> None:
        await self._http.aclose()

    async def run(self, name: str, args: dict[str, Any]) -> ToolOutcome:
        try:
            response = await self._dispatch(name, args)
        except KeyError as missing:
            return ToolOutcome(f"Missing required argument {missing}.", is_error=True)
        except (TypeError, ValueError) as bad:
            return ToolOutcome(f"Invalid argument: {bad}", is_error=True)
        except httpx.HTTPError as error:
            return ToolOutcome(f"The booking system is unreachable ({type(error).__name__}). Try again shortly.", is_error=True)
        if response is None:
            return ToolOutcome(f"Unknown tool: {name}", is_error=True)

        # 4xx bodies are ProblemDetails explaining what was wrong (validation, sold out, not found),
        # which Claude can relay to the guest, so they're returned as error results rather than raised.
        ok = response.is_success
        return ToolOutcome(
            content=response.text or json.dumps({"status": response.status_code}),
            is_error=not ok,
            changed_bookings=ok and name in _MUTATING,
        )

    async def _dispatch(self, name: str, a: dict[str, Any]) -> httpx.Response | None:
        match name:
            case "search_destinations":
                params = {
                    "q": a.get("query"),
                    "category": a.get("category"),
                    "maxPrice": a.get("max_price_per_night"),
                    "guests": a.get("guests"),
                    "checkIn": a.get("check_in"),
                    "checkOut": a.get("check_out"),
                    "availableOnly": str(a["available_only"]).lower() if "available_only" in a else None,
                }
                return await self._http.get("/api/destinations", params={k: v for k, v in params.items() if v is not None})
            case "check_availability":
                return await self._http.get(
                    f"/api/destinations/{int(a['destination_id'])}/availability",
                    params={"checkIn": a["check_in"], "checkOut": a["check_out"], "guests": a["guests"]},
                )
            case "create_reservation":
                return await self._http.post("/api/reservations", json={
                    "destinationId": a["destination_id"],
                    "guestName": a["guest_name"],
                    "guestEmail": a["guest_email"],
                    "checkIn": a["check_in"],
                    "checkOut": a["check_out"],
                    "guests": a["guests"],
                    "source": "CHAT",
                })
            case "get_reservation":
                return await self._http.get(f"/api/reservations/{a['confirmation_code']}", params={"email": a["email"]})
            case "list_reservations":
                return await self._http.get("/api/reservations", params={"email": a["email"]})
            case "get_trip_forecast":
                return await self._http.get(f"/api/reservations/{a['confirmation_code']}/forecast", params={"email": a["email"]})
            case "cancel_reservation":
                return await self._http.post(f"/api/reservations/{a['confirmation_code']}/cancel", json={"email": a["email"]})
            case _:
                return None
