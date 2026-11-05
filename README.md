# Horizon Getaways – vacation reservations demo

A small vacation-booking app that runs entirely on one Windows Server EC2 host:

- **Web UI** – plain HTML/CSS/JS (no build step): search destinations, see live availability and prices, book, look up and cancel trips, and chat with an assistant.
- **API** – ASP.NET Core (.NET 10, C#) minimal API hosted in **IIS**, using Dapper + `Oracle.ManagedDataAccess.Core`.
- **Database** – **Oracle Database 21c Express Edition**, pluggable database `XEPDB1`, schema `VACATION`.
- **Chatbot** – **Python** FastAPI service using the **Anthropic** SDK (Claude tool use). It can search, quote, book, look up and cancel reservations, and give weather and packing advice for a booked trip.
- **Trip forecast** – an **Azure Function** (HTTP trigger, .NET 10 isolated, Flex Consumption) that returns day-by-day weather and a packing list for a stay, using Open-Meteo. It sends logs, traces and metrics to **Application Insights** through OpenTelemetry. This is the only part not on the EC2 host.

```
 Browser ──HTTP :80──▶ IIS site "Vacations"
                        ├─ /chat/*  ──URL Rewrite + ARR──▶ Python chatbot (uvicorn 127.0.0.1:8001)
                        │                                     │  Claude API (tool use)
                        │                                     └─ tools call ──HTTP──▶ /api/* (below)
                        └─ /api/*, static UI ──ASP.NET Core Module──▶ Vacations.Api ──▶ Oracle XE (localhost:1521/XEPDB1)
                                                                          │
                                         /api/reservations/{code}/forecast └─HTTPS + function key──▶ Azure Function
                                                                              GET /api/forecast ──▶ Open-Meteo
                                                                              └─ OpenTelemetry ──▶ Application Insights
```

The chatbot's tools call the .NET API over HTTP rather than the database, so pricing, availability and overbooking rules live in one place (`VacationStore.cs`). Only port 80 is exposed; Oracle and the chatbot listen on localhost only.

## Repository layout

| Path | What it is |
|---|---|
| `db/` | Oracle scripts: `01_create_user.sql`, `02_schema.sql`, `03_drop.sql`, `04_seed.sql`, idempotent migrations `05_chat.sql` and `06_geo.sql` (destination coordinates), and the `setup-db.ps1` wrapper |
| `src/Vacations.Api/` | ASP.NET Core API + `wwwroot/` web UI + `web.config` (IIS, including the `/chat` proxy rule) |
| `chatbot/` | FastAPI app (`app.py`), Claude loop (`agent.py`), tools (`tools.py`), `requirements.txt`, `install-service.ps1` |
| `infra/provision-ec2.ps1` | One-time host setup: IIS, URL Rewrite, ARR, .NET SDK + Hosting Bundle, Python, Oracle XE |
| `infra/deploy.sh` | Runs `provision-ec2.ps1` on the instance through SSM Run Command from your workstation |
| `infra/deploy-app.ps1` | Deploys the API/UI to IIS and installs the chatbot service (runs on the server) |
| `infra/ship.sh` | From your workstation: zips the repo to S3, then over SSM runs `setup-db.ps1` and `deploy-app.ps1` on the host |
| `functions/Vacations.Forecast/` | The trip-forecast Azure Function (`ForecastFunction.cs`, `OpenMeteoClient.cs`, `PackingList.cs`, `Telemetry.cs`) |
| `infra/azure/deploy-forecast.sh` | Creates or updates the Function App, storage and Application Insights, deploys the function and hands its URL and key to the host |

## Data model

- `DESTINATIONS` – name, country, region, category (BEACH, ISLAND, MOUNTAIN, CITY, COUNTRYSIDE, SAFARI), description, `price_per_night`, `max_guests` per booking, `rooms` (units bookable per night) and rating. Seeded with 12 destinations.
- `RESERVATIONS` – confirmation code (`VAC-XXXXXX`), destination, guest name and email, check-in and check-out dates, guests, total price, status (CONFIRMED or CANCELLED), source (WEB or CHAT), and created/cancelled timestamps. The seed adds two upcoming trips for `demo@example.com` (codes `VAC-DEMO01` and `VAC-DEMO02`).

**Availability rule:** each reservation takes one unit for every night of its stay. A stay is available if, on its busiest night, fewer than `rooms` confirmed reservations overlap. Each booking locks its destination row (`SELECT … FOR UPDATE`) inside a transaction, so concurrent requests can't double-book the last unit.

## API

| Method & path | Purpose | Notable responses |
|---|---|---|
| `GET /api/health` | API + database check | 503 if Oracle is unreachable |
| `GET /api/destinations?q=&category=&maxPrice=&guests=&checkIn=&checkOut=&availableOnly=` | Search. When both dates are given, each result includes a `quote` (nights, total, rooms left, available) | 400 on invalid dates |
| `GET /api/destinations/{id}` | One destination | 404 |
| `GET /api/destinations/{id}/availability?checkIn=&checkOut=&guests=` | Quote for one destination | 400, 404 |
| `POST /api/reservations` | Book: `{destinationId, guestName, guestEmail, checkIn, checkOut, guests, source}` | 201, 400 (validation), 404, 409 (sold out) |
| `GET /api/reservations?email=` | List a guest's reservations | 400 |
| `GET /api/reservations/{code}?email=` | Look up one reservation (needs the code and the email) | 404 |
| `POST /api/reservations/{code}/cancel` | Cancel before check-in: `{email}` | 404, 409 (already cancelled or already started) |
| `GET /api/reservations/{code}/forecast?email=` | Weather for each day of the stay plus a packing list, from the Azure Function | 404, 502 (function or weather provider failed), 503 (not configured) |

Dates are `YYYY-MM-DD`. Stays must start today or later, be at most 30 nights, and start at most 18 months ahead. Errors are returned as RFC 9110 ProblemDetails.

Chatbot endpoints (behind IIS at `/chat`): `POST /chat/api/message {session_id, message}` returns `{session_id, reply, bookings_changed}`. There are also `GET /chat/api/history/{session_id}` (visible transcript, used by the UI to restore the chat after a reload), `POST /chat/api/reset` and `GET /chat/health`. Conversation history is stored in Oracle (`VACATION.CHAT_SESSIONS`, one JSON document per session, created by `db/05_chat.sql`), so it survives restarts; sessions not used for `CHAT_RETENTION_DAYS` (default 30) are deleted when the chatbot starts.

### Trip forecast function

`GET https://<function-app>/api/forecast?lat=&lon=&from=&to=&place=&category=` needs the `x-functions-key` header. It returns `{place, mode, from, to, summary, days: [{date, highC, lowC, precipChance, weatherCode, summary}], packing: [...]}`.
- **Mode:** `forecast` uses the live Open-Meteo forecast when the whole stay is within 15 days. Otherwise it is `climate`: the same dates averaged over the last 3 years, fetched in parallel.
- **Caching:** results are cached in memory for 30 minutes (forecast) or 12 hours (climate).
- **Errors:** 400 for invalid input, 401 without the key, 502 if Open-Meteo fails.

In Application Insights (`appi-vacations-forecast`) you can see:
- request telemetry for every call;
- Open-Meteo calls as HTTP dependencies, with climate requests grouped under a `ClimateNormals` span;
- a `BuildPackingList` span;
- structured logs correlated by operation ID;
- the `forecast.requests` custom metric, split by mode, cache result and category.

## Datadog RUM and APM

- **RUM:** `wwwroot/datadog-rum.js` loads the browser SDK (service `vacations-web`, env `demo`, Session Replay with typed input masked). The app ID and client token are in `wwwroot/datadog-rum-config.js`. Without that file, RUM stays off.
- **Who the session belongs to:** there are no accounts, so each session is tagged with the guest's email (`usr.email`) when they book, look up their trips or return with a saved email.
- **APM:** when the Datadog Agent is installed on the host, `deploy-app.ps1` installs the Datadog .NET tracer (`-DatadogTracerVersion`, default 3.57.0). It also sets `DD_SERVICE=vacations-api` and `DD_ENV=demo` on the app pool.
- **RUM to APM:** RUM adds trace headers to same-origin `/api/` calls, so a click in RUM links to the `vacations-api` trace. That trace includes the outbound call to the forecast function.
- **Not traced:** the chatbot (`/chat`).

## Configuration and secrets

Nothing secret is committed.

| Setting | Where it lives on the server |
|---|---|
| Oracle SYS password | `C:\setup\secrets\oracle-xe-sys-password.txt` (Administrators only) |
| `VACATION` schema password | `C:\setup\secrets\oracle-vacation-password.txt`, generated by `db/setup-db.ps1` |
| API connection string `ConnectionStrings__Oracle` | Environment variable on the `Vacations` IIS app pool, stored in `applicationHost.config` and set by `deploy-app.ps1` |
| `ANTHROPIC_API_KEY`, `VACATIONS_API_URL` | `C:\apps\chatbot\.env`, readable only by Administrators, SYSTEM and LOCAL SERVICE (see `chatbot/.env.example`) |
| Forecast function URL and key (`Forecast__BaseUrl`, `Forecast__FunctionKey`) | `C:\setup\secrets\forecast-function-url.txt` and `forecast-function-key.txt`, written by `infra/azure/deploy-forecast.sh`. `deploy-app.ps1` copies them into app pool environment variables. |
| Optional chatbot settings | `CLAUDE_MODEL` (default `claude-opus-5-5`), `CLAUDE_EFFORT` (default `medium`), `CLAUDE_FALLBACKS` (`default`, or `off`), `CHAT_RETENTION_DAYS` |

The chatbot turns on Anthropic's server-side refusal fallback (`fallbacks: "default"`) by default. If Claude's safety classifiers decline a request, the API retries it on Anthropic's recommended fallback model. Set `CLAUDE_FALLBACKS=off` to disable this.

## Deploying to the EC2 host

1. **Provision the host** (once) – from your workstation: `AWS_PROFILE=… AWS_REGION=us-east-2 ./infra/deploy.sh <instance-id>`.
   - If the unattended Oracle XE install fails, install it interactively instead. In that case, write the SYS password to `C:\setup\secrets\oracle-xe-sys-password.txt`.
   - Make sure the listener also listens on `localhost`.
2. **Get the repo onto the server.** `./infra/ship.sh <instance-id>` does this and also runs steps 3 and 4. It needs the instance to be able to reach the artifacts bucket through a presigned URL, and the chatbot `.env` must already exist.
3. **Create the schema** – on the server, in an Administrator PowerShell: `.\db\setup-db.ps1`. Add `-Reset` to drop the tables and reseed.
4. **Deploy the app** – `.\infra\deploy-app.ps1`. It prompts once for the Anthropic API key, then:
   - publishes the API to `C:\inetpub\vacations`;
   - creates the `Vacations` site (port 80) with a "No Managed Code" app pool, and stops the IIS default site;
   - installs the chatbot into `C:\apps\chatbot` and registers it as the `VacationsChatbot` scheduled task;
   - smoke-tests `/api/health`, `/` and `/chat/health`.
5. Open the instance's public IP in a browser. The security group must allow inbound TCP 80.
6. **Trip forecasts (optional).** After `az login`, run `AWS_PROFILE=… AWS_REGION=us-east-2 ./infra/azure/deploy-forecast.sh <instance-id>`, then `./infra/ship.sh <instance-id>`.
   - Everything is created in resource group `rg-vacations-forecast`; `az group delete -n rg-vacations-forecast` removes it.
   - Without this step, the trips page shows "Trip forecasts are not available".

Logs:
- API: Windows Event Log (Application). Set `stdoutLogEnabled="true"` in `web.config` to also write to `C:\inetpub\vacations\logs`.
- Chatbot: `C:\apps\chatbot\logs\chatbot.log`.

## Local development

You need the .NET 10 SDK, Python 3.12+ and an Oracle database you can reach (for example Oracle XE or `gvenzl/oracle-free`, which needs at least 2 GB of RAM).

```bash
# API + UI on http://localhost:5000. In Development, it forwards /chat/* to the chatbot itself, since there is no IIS.
export ConnectionStrings__Oracle="User Id=vacation;Password=...;Data Source=localhost:1521/XEPDB1"
dotnet run --project src/Vacations.Api

# Chatbot on 127.0.0.1:8001
cd chatbot
python -m venv .venv && . .venv/bin/activate && pip install -r requirements.txt
cp .env.example .env   # set ANTHROPIC_API_KEY and VACATIONS_API_URL=http://localhost:5000
uvicorn app:app --host 127.0.0.1 --port 8001 --reload
```

To load the schema against a non-Windows database, run the SQL files with sqlplus or SQLcl:
- `01_create_user.sql` as SYS, after `DEFINE app_password = '...'`;
- then `02_schema.sql`, `04_seed.sql`, `05_chat.sql` and `06_geo.sql` as `vacation`.
