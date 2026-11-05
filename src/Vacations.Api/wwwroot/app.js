"use strict";

const ART = { BEACH: "🏖️", ISLAND: "🏝️", MOUNTAIN: "🏔️", CITY: "🏙️", COUNTRYSIDE: "🌿", SAFARI: "🦒" };
const money = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", maximumFractionDigits: 0 });
const $ = (selector) => document.querySelector(selector);

// ---------- helpers

function escapeHtml(text) {
  return String(text).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
}

function isoDate(date) {
  const local = new Date(date.getTime() - date.getTimezoneOffset() * 60000);
  return local.toISOString().slice(0, 10);
}

function addDays(date, days) {
  const copy = new Date(date);
  copy.setDate(copy.getDate() + days);
  return copy;
}

function formatDate(iso) {
  return new Date(`${iso}T00:00:00`).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" });
}

// Turns an ASP.NET Core ProblemDetails / ValidationProblem response into a readable message.
async function problemMessage(response) {
  try {
    const body = await response.json();
    if (body.errors) return Object.values(body.errors).flat().join(" ");
    return body.detail || body.title || `Request failed (${response.status})`;
  } catch {
    return `Request failed (${response.status})`;
  }
}

async function api(path, options = {}) {
  const response = await fetch(path, {
    ...options,
    headers: { "Content-Type": "application/json", ...(options.headers || {}) },
  });
  if (!response.ok) throw new Error(await problemMessage(response));
  return response.status === 204 ? null : response.json();
}

function showError(element, message) {
  element.textContent = message || "";
  element.hidden = !message;
}

// ---------- search

const searchForm = $("#search-form");
let lastSearch = null;

function initDates() {
  const today = new Date();
  searchForm.checkIn.min = isoDate(today);
  searchForm.checkOut.min = isoDate(addDays(today, 1));
  searchForm.checkIn.value = isoDate(addDays(today, 14));
  searchForm.checkOut.value = isoDate(addDays(today, 19));
  searchForm.checkIn.addEventListener("change", () => {
    const checkIn = new Date(`${searchForm.checkIn.value}T00:00:00`);
    searchForm.checkOut.min = isoDate(addDays(checkIn, 1));
    if (searchForm.checkOut.value <= searchForm.checkIn.value) searchForm.checkOut.value = isoDate(addDays(checkIn, 5));
  });
}

async function search() {
  const data = new FormData(searchForm);
  const params = new URLSearchParams();
  for (const [key, value] of data) if (value) params.set(key, value);
  lastSearch = Object.fromEntries(params);

  const results = $("#results");
  results.innerHTML = Array.from({ length: 6 }, () => '<div class="skeleton"></div>').join("");
  showError($("#search-error"), "");

  try {
    const destinations = await api(`/api/destinations?${params}`);
    renderResults(destinations);
  } catch (error) {
    results.innerHTML = "";
    showError($("#search-error"), error.message);
  }
}

function availabilityBadge(quote) {
  if (!quote) return "";
  if (!quote.available) return '<span class="badge none">Sold out</span>';
  if (quote.roomsLeft <= 3) return `<span class="badge low">Only ${quote.roomsLeft} left</span>`;
  return '<span class="badge ok">Available</span>';
}

function renderResults(destinations) {
  const results = $("#results");
  const nights = destinations[0]?.quote?.nights;
  $("#results-meta").textContent = destinations.length
    ? `${destinations.length} ${destinations.length === 1 ? "stay" : "stays"}` +
      (nights ? ` · ${formatDate(lastSearch.checkIn)} – ${formatDate(lastSearch.checkOut)} · ${nights} nights` : "")
    : "";

  if (!destinations.length) {
    results.innerHTML = '<p class="empty">No destinations match your search. Try fewer words or different dates.</p>';
    return;
  }

  results.innerHTML = destinations.map((d) => `
    <article class="card">
      <div class="card-art art-${escapeHtml(d.category)}">
        ${availabilityBadge(d.quote)}
        <span class="rating">★ ${d.rating.toFixed(1)}</span>
        <span aria-hidden="true">${ART[d.category] || "✈️"}</span>
      </div>
      <div class="card-body">
        <h3>${escapeHtml(d.name)}</h3>
        <p class="place">${escapeHtml(d.region)}, ${escapeHtml(d.country)} · up to ${d.maxGuests} guests</p>
        <p class="desc">${escapeHtml(d.description)}</p>
        <div class="card-foot">
          <div class="price">
            <strong>${money.format(d.pricePerNight)}</strong> <span class="muted">/ night</span>
            ${d.quote ? `<span class="total">${money.format(d.quote.totalPrice)} total</span>` : ""}
          </div>
          <button class="primary" type="button" data-book="${d.id}" ${d.quote && !d.quote.available ? "disabled" : ""}>
            ${d.quote && !d.quote.available ? "Unavailable" : "Book"}
          </button>
        </div>
      </div>
    </article>`).join("");

  results.querySelectorAll("[data-book]").forEach((button) => {
    const destination = destinations.find((d) => String(d.id) === button.dataset.book);
    button.addEventListener("click", () => openBooking(destination));
  });
}

searchForm.addEventListener("submit", (event) => {
  event.preventDefault();
  search();
});

// ---------- booking

const dialog = $("#booking-dialog");
const bookingForm = $("#booking-form");
let bookingDestination = null;

function openBooking(destination) {
  bookingDestination = destination;
  const quote = destination.quote;
  $("#booking-title").textContent = destination.name;
  $("#booking-summary").innerHTML = `
    <div class="row"><span>Dates</span><span>${formatDate(quote.checkIn)} – ${formatDate(quote.checkOut)}</span></div>
    <div class="row"><span>Guests</span><span>${quote.guests}</span></div>
    <div class="row"><span>${money.format(destination.pricePerNight)} × ${quote.nights} nights</span><span>${money.format(quote.totalPrice)}</span></div>
    <div class="row total"><span>Total</span><span>${money.format(quote.totalPrice)}</span></div>`;
  showError($("#booking-error"), "");
  bookingForm.hidden = false;
  $("#booking-confirmation").hidden = true;
  const savedEmail = localStorage.getItem("guestEmail");
  if (savedEmail && !bookingForm.guestEmail.value) bookingForm.guestEmail.value = savedEmail;
  dialog.showModal();
}

bookingForm.addEventListener("submit", async (event) => {
  if (event.submitter?.value === "cancel") return; // let the dialog close
  event.preventDefault();
  const submit = $("#booking-submit");
  submit.disabled = true;
  showError($("#booking-error"), "");

  try {
    const quote = bookingDestination.quote;
    const reservation = await api("/api/reservations", {
      method: "POST",
      body: JSON.stringify({
        destinationId: bookingDestination.id,
        guestName: bookingForm.guestName.value,
        guestEmail: bookingForm.guestEmail.value,
        checkIn: quote.checkIn,
        checkOut: quote.checkOut,
        guests: quote.guests,
        source: "WEB",
      }),
    });
    rememberGuest(reservation.guestEmail, reservation.guestName);
    showConfirmation(reservation);
    search();
    loadTrips(reservation.guestEmail);
  } catch (error) {
    showError($("#booking-error"), error.message);
  } finally {
    submit.disabled = false;
  }
});

function showConfirmation(reservation) {
  bookingForm.hidden = true;
  const confirmation = $("#booking-confirmation");
  confirmation.hidden = false;
  confirmation.innerHTML = `
    <div class="check">✔</div>
    <h3>You're going to ${escapeHtml(reservation.destinationName)}!</h3>
    <p class="muted">${formatDate(reservation.checkIn)} – ${formatDate(reservation.checkOut)} · ${reservation.guests} guests · ${money.format(reservation.totalPrice)}</p>
    <div class="code">${escapeHtml(reservation.confirmationCode)}</div>
    <p class="muted small">A confirmation was recorded for ${escapeHtml(reservation.guestEmail)}.</p>
    <button class="primary" type="button" id="confirmation-done">Done</button>`;
  $("#confirmation-done").addEventListener("click", () => dialog.close());
}

// ---------- guest identity (the demo has no accounts; the guest's email is who they are)

function rememberGuest(email, name) {
  localStorage.setItem("guestEmail", email);
  identifyRumUser(email, name);
}

// Tags Datadog RUM sessions with the guest so a session can be found by email (no-op if RUM isn't configured).
function identifyRumUser(email, name) {
  if (!email || !window.__DD_RUM__?.applicationId) return;
  window.DD_RUM?.onReady(() => {
    if (window.DD_RUM.getUser().id !== email) window.DD_RUM.setUser({ id: email, email });
    if (name) window.DD_RUM.setUserProperty("name", name);
  });
}

// ---------- my trips

const tripsForm = $("#trips-form");

async function loadTrips(email) {
  if (!email) return;
  tripsForm.email.value = email;
  showError($("#trips-error"), "");
  const list = $("#trip-list");
  try {
    const trips = await api(`/api/reservations?email=${encodeURIComponent(email)}`);
    rememberGuest(email);
    renderTrips(trips, email);
  } catch (error) {
    list.innerHTML = "";
    showError($("#trips-error"), error.message);
  }
}

function renderTrips(trips, email) {
  const list = $("#trip-list");
  if (!trips.length) {
    list.innerHTML = '<p class="muted">No reservations found for that email yet.</p>';
    return;
  }
  const today = isoDate(new Date());
  list.innerHTML = trips.map((t) => `
    <article class="trip ${t.status === "CANCELLED" ? "cancelled" : ""}">
      <div class="trip-main">
        <h3>${escapeHtml(t.destinationName)} <span class="muted small">${escapeHtml(t.country)}</span></h3>
        <div class="muted small">${formatDate(t.checkIn)} – ${formatDate(t.checkOut)} · ${t.nights} nights · ${t.guests} guests
          ${t.source === "CHAT" ? " · booked via assistant" : ""}</div>
      </div>
      <span class="code">${escapeHtml(t.confirmationCode)}</span>
      <strong>${money.format(t.totalPrice)}</strong>
      <span class="status ${t.status}">${t.status}</span>
      ${t.status === "CONFIRMED" && t.checkOut >= today
        ? `<button class="secondary" type="button" data-forecast="${escapeHtml(t.confirmationCode)}" aria-expanded="false">Weather &amp; packing</button>` : ""}
      ${t.status === "CONFIRMED" && t.checkIn > today
        ? `<button class="danger" type="button" data-cancel="${escapeHtml(t.confirmationCode)}">Cancel</button>` : ""}
      <div class="forecast" hidden></div>
    </article>`).join("");

  list.querySelectorAll("[data-cancel]").forEach((button) =>
    button.addEventListener("click", () => cancelTrip(button.dataset.cancel, email, button)));
  list.querySelectorAll("[data-forecast]").forEach((button) =>
    button.addEventListener("click", () => toggleForecast(button, email)));
}

// ---------- trip weather (served by the Azure Function through /api/reservations/{code}/forecast)

function weatherIcon(code) {
  if (code === 0) return "☀️";
  if (code <= 2) return "🌤️";
  if (code === 3) return "☁️";
  if (code === 45 || code === 48) return "🌫️";
  if (code >= 95) return "⛈️";
  if ((code >= 71 && code <= 77) || code === 85 || code === 86) return "❄️";
  if (code >= 80) return "🌦️";
  return "🌧️";
}

async function toggleForecast(button, email) {
  const panel = button.closest(".trip").querySelector(".forecast");
  const open = panel.hidden;
  panel.hidden = !open;
  button.setAttribute("aria-expanded", String(open));
  if (!open || panel.dataset.loaded) return;

  panel.innerHTML = '<p class="muted small">Checking the weather…</p>';
  try {
    const f = await api(`/api/reservations/${encodeURIComponent(button.dataset.forecast)}/forecast?email=${encodeURIComponent(email)}`);
    panel.dataset.loaded = "true";
    panel.innerHTML = `
      <p class="forecast-head"><strong>${escapeHtml(f.place)}</strong> · ${escapeHtml(f.summary)}
        <span class="muted small">${f.mode === "climate"
          ? "Typical weather for these dates, based on the last 3 years."
          : "Live forecast."}</span></p>
      <div class="forecast-days">${f.days.map((d) => `
        <div class="day" title="${escapeHtml(d.summary)}">
          <div class="muted small">${new Date(`${d.date}T00:00:00`).toLocaleDateString("en-US", { weekday: "short", month: "short", day: "numeric" })}</div>
          <div class="icon" aria-hidden="true">${weatherIcon(d.weatherCode)}</div>
          <div><strong>${d.highC}°</strong> <span class="muted">${d.lowC}°</span></div>
          <div class="muted small">💧 ${d.precipChance}%</div>
        </div>`).join("")}</div>
      <h4>What to pack</h4>
      <ul class="packing">${f.packing.map((item) => `<li>${escapeHtml(item)}</li>`).join("")}</ul>`;
  } catch (error) {
    panel.innerHTML = `<p class="notice error">${escapeHtml(error.message)}</p>`;
  }
}

async function cancelTrip(code, email, button) {
  if (!confirm(`Cancel reservation ${code}? This can't be undone.`)) return;
  button.disabled = true;
  try {
    await api(`/api/reservations/${encodeURIComponent(code)}/cancel`, { method: "POST", body: JSON.stringify({ email }) });
    await loadTrips(email);
    search();
  } catch (error) {
    showError($("#trips-error"), error.message);
    button.disabled = false;
  }
}

tripsForm.addEventListener("submit", (event) => {
  event.preventDefault();
  loadTrips(tripsForm.email.value.trim());
});

// ---------- chat assistant

const chat = $("#chat");
const chatLog = $("#chat-log");
const chatForm = $("#chat-form");
const chatInput = chatForm.message;
let chatSession = localStorage.getItem("chatSession") || "";

// Minimal, safe formatting for assistant replies: escape first, then bold, inline code, bullets and paragraphs.
function renderMarkdown(text) {
  const inline = (s) => escapeHtml(s).replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>").replace(/`([^`]+)`/g, "<code>$1</code>");
  return text.split(/\n{2,}/).map((block) => {
    const lines = block.split("\n");
    if (lines.every((l) => /^\s*[-*•]\s+/.test(l))) {
      return `<ul>${lines.map((l) => `<li>${inline(l.replace(/^\s*[-*•]\s+/, ""))}</li>`).join("")}</ul>`;
    }
    return `<p>${lines.map(inline).join("<br>")}</p>`;
  }).join("");
}

function addMessage(role, text) {
  const div = document.createElement("div");
  div.className = `msg ${role}`;
  if (role === "bot") div.innerHTML = renderMarkdown(text);
  else div.textContent = text;
  chatLog.appendChild(div);
  chatLog.scrollTop = chatLog.scrollHeight;
  return div;
}

function greet() {
  chatLog.innerHTML = "";
  addMessage("bot", "Hi! I'm your Horizon Getaways assistant. Tell me where you'd like to go, when, and how many travelers - " +
    "I can find availability, book a stay, or look up and cancel an existing reservation.");
}

// Conversations are stored server-side, so a returning visitor picks up where they left off.
async function restoreChat() {
  greet();
  if (!chatSession) return;
  try {
    const response = await fetch(`/chat/api/history/${encodeURIComponent(chatSession)}`);
    if (response.status === 404) {
      chatSession = "";
      localStorage.removeItem("chatSession");
      return;
    }
    if (!response.ok) return;
    const { messages } = await response.json();
    messages.forEach((m) => addMessage(m.role === "user" ? "user" : "bot", m.text));
  } catch {
    // Offline or chatbot down: start from the greeting; sending a message will surface the error.
  }
}

function openChat() {
  chat.hidden = false;
  $(".chat-fab").hidden = true;
  if (!chatLog.children.length) restoreChat();
  chatInput.focus();
}

function closeChat() {
  chat.hidden = true;
  $(".chat-fab").hidden = false;
}

document.querySelectorAll("[data-open-chat]").forEach((el) => el.addEventListener("click", openChat));
$("#chat-close").addEventListener("click", closeChat);
$("#chat-reset").addEventListener("click", async () => {
  if (chatSession) fetch("/chat/api/reset", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ session_id: chatSession }) }).catch(() => {});
  chatSession = "";
  localStorage.removeItem("chatSession");
  greet();
});

chatInput.addEventListener("keydown", (event) => {
  if (event.key === "Enter" && !event.shiftKey) {
    event.preventDefault();
    chatForm.requestSubmit();
  }
});

chatForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  const message = chatInput.value.trim();
  if (!message) return;
  chatInput.value = "";
  addMessage("user", message);
  const typing = addMessage("bot", "");
  typing.innerHTML = '<span class="typing"><span></span><span></span><span></span></span>';
  const send = chatForm.querySelector("button");
  send.disabled = true;

  try {
    const response = await fetch("/chat/api/message", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ session_id: chatSession || null, message }),
    });
    if (!response.ok) throw new Error(await chatError(response));
    const body = await response.json();
    chatSession = body.session_id;
    localStorage.setItem("chatSession", chatSession);
    typing.remove();
    addMessage("bot", body.reply);
    if (body.bookings_changed) {
      search();
      loadTrips(tripsForm.email.value.trim() || localStorage.getItem("guestEmail"));
    }
  } catch (error) {
    typing.remove();
    addMessage("error", error.message || "The assistant is unavailable right now.");
  } finally {
    send.disabled = false;
    chatInput.focus();
  }
});

async function chatError(response) {
  try {
    const body = await response.json();
    return typeof body.detail === "string" ? body.detail : `Assistant error (${response.status})`;
  } catch {
    return response.status === 502 || response.status === 503
      ? "The assistant service isn't running."
      : `Assistant error (${response.status})`;
  }
}

// ---------- start

initDates();
search();
identifyRumUser(localStorage.getItem("guestEmail"));
loadTrips(localStorage.getItem("guestEmail"));
