namespace Vacations.Api;

public static class Endpoints
{
    public static void MapVacationApi(this IEndpointRouteBuilder app)
    {
        var api = app.MapGroup("/api");

        api.MapGet("/health", async (VacationStore store, ILogger<VacationStore> logger) =>
        {
            try
            {
                await store.PingAsync();
                return Results.Ok(new { status = "ok", database = "ok" });
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "Database health check failed");
                return Results.Json(new { status = "degraded", database = ex.Message }, statusCode: StatusCodes.Status503ServiceUnavailable);
            }
        });

        // Search destinations; when both dates are given, each result carries a price/availability quote.
        api.MapGet("/destinations", async (
            string? q, string? category, decimal? maxPrice, int? guests, DateOnly? checkIn, DateOnly? checkOut,
            bool? availableOnly, VacationStore store) =>
        {
            var validation = new Validation();
            if (checkIn.HasValue != checkOut.HasValue) validation.Add("checkOut", "Provide both checkIn and checkOut, or neither.");
            if (checkIn is { } inDate && checkOut is { } outDate) validation.Stay(inDate, outDate);
            if (guests is { } g) validation.Guests(g);
            if (!validation.IsValid) return Results.ValidationProblem(validation.Errors);

            var destinations = await store.SearchAsync(q, category, maxPrice, guests);
            if (checkIn is null || checkOut is null || destinations.Count == 0)
                return Results.Ok(destinations.Select(d => DestinationView.From(d)));

            var quotes = await store.QuoteAsync(destinations, checkIn.Value, checkOut.Value, guests ?? 1);
            var results = destinations
                .Select(d => DestinationView.From(d, quotes[d.Id]))
                .Where(d => availableOnly != true || d.Quote!.Available);
            return Results.Ok(results);
        });

        api.MapGet("/destinations/{id:long}", async (long id, VacationStore store) =>
            await store.GetDestinationAsync(id) is { } d
                ? Results.Ok(DestinationView.From(d))
                : Results.Problem(statusCode: 404, title: "Destination not found"));

        api.MapGet("/destinations/{id:long}/availability", async (
            long id, DateOnly checkIn, DateOnly checkOut, int? guests, VacationStore store) =>
        {
            var validation = new Validation();
            validation.Stay(checkIn, checkOut);
            validation.Guests(guests ?? 1);
            if (!validation.IsValid) return Results.ValidationProblem(validation.Errors);

            if (await store.GetDestinationAsync(id) is not { } destination)
                return Results.Problem(statusCode: 404, title: "Destination not found");
            var quotes = await store.QuoteAsync([destination], checkIn, checkOut, guests ?? 1);
            return Results.Ok(DestinationView.From(destination, quotes[id]));
        });

        api.MapPost("/reservations", async (CreateReservationRequest request, VacationStore store) =>
        {
            var validation = new Validation();
            var name = validation.Name(request.GuestName);
            var email = validation.Email(request.GuestEmail);
            validation.Stay(request.CheckIn, request.CheckOut);
            validation.Guests(request.Guests);
            var source = (request.Source ?? "WEB").Trim().ToUpperInvariant();
            if (source is not ("WEB" or "CHAT")) validation.Add("source", "Source must be WEB or CHAT.");
            if (!validation.IsValid) return Results.ValidationProblem(validation.Errors);

            var result = await store.CreateReservationAsync(
                request.DestinationId, name!, email!, request.CheckIn, request.CheckOut, request.Guests, source);
            return result.Status switch
            {
                BookingStatus.Created => Results.Created($"/api/reservations/{result.Reservation!.ConfirmationCode}", result.Reservation),
                BookingStatus.DestinationNotFound => Results.Problem(statusCode: 404, title: "Destination not found"),
                BookingStatus.TooManyGuests => Results.ValidationProblem(new Dictionary<string, string[]>
                {
                    ["guests"] = [$"This destination accommodates at most {result.MaxGuests} guests per booking."],
                }),
                _ => Results.Problem(statusCode: 409, title: "Not available",
                    detail: "This destination is fully booked for at least one night of the requested stay."),
            };
        });

        api.MapGet("/reservations", async (string? email, VacationStore store) =>
        {
            var validation = new Validation();
            var normalized = validation.Email(email, "email");
            if (!validation.IsValid) return Results.ValidationProblem(validation.Errors);
            return Results.Ok(await store.ListReservationsAsync(normalized!));
        });

        // Lookups and cancellations require the guest's email as well as the code, so codes alone can't be enumerated.
        api.MapGet("/reservations/{code}", async (string code, string? email, VacationStore store) =>
        {
            var validation = new Validation();
            var normalized = validation.Email(email, "email");
            if (!validation.IsValid) return Results.ValidationProblem(validation.Errors);
            return await store.GetReservationAsync(code, normalized!) is { } reservation
                ? Results.Ok(reservation)
                : Results.Problem(statusCode: 404, title: "Reservation not found",
                    detail: "No reservation matches that confirmation code and email.");
        });

        // Weather for each day of the stay plus a packing list, from the trip-forecast Azure Function.
        api.MapGet("/reservations/{code}/forecast", async (
            string code, string? email, VacationStore store, ForecastClient forecast, ILogger<ForecastClient> logger,
            CancellationToken ct) =>
        {
            var validation = new Validation();
            var normalized = validation.Email(email, "email");
            if (!validation.IsValid) return Results.ValidationProblem(validation.Errors);
            if (!forecast.IsConfigured)
                return Results.Problem(statusCode: 503, title: "Trip forecasts are not available",
                    detail: "The forecast service has not been configured on this server.");

            if (await store.GetReservationAsync(code, normalized!) is not { } reservation)
                return Results.Problem(statusCode: 404, title: "Reservation not found",
                    detail: "No reservation matches that confirmation code and email.");
            if (await store.GetDestinationAsync(reservation.DestinationId) is not { Latitude: not null, Longitude: not null } destination)
                return Results.Problem(statusCode: 404, title: "No location on file",
                    detail: "This destination has no coordinates, so a forecast isn't available.");

            try
            {
                using var response = await forecast.GetAsync(destination, reservation.CheckIn, reservation.CheckOut, ct);
                var body = await response.Content.ReadAsStringAsync(ct);
                if (response.IsSuccessStatusCode) return Results.Content(body, "application/json");
                logger.LogWarning("Forecast function returned {Status} for {Code}: {Body}", (int)response.StatusCode, reservation.ConfirmationCode, body);
            }
            catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException && !ct.IsCancellationRequested)
            {
                logger.LogError(ex, "Forecast function call failed for {Code}", reservation.ConfirmationCode);
            }
            return Results.Problem(statusCode: 502, title: "Weather service unavailable",
                detail: "Could not get the forecast right now. Try again shortly.");
        });

        api.MapPost("/reservations/{code}/cancel", async (string code, CancelReservationRequest request, VacationStore store) =>
        {
            var validation = new Validation();
            var email = validation.Email(request.Email, "email");
            if (!validation.IsValid) return Results.ValidationProblem(validation.Errors);

            var result = await store.CancelReservationAsync(code, email!, Validation.Today);
            return result.Status switch
            {
                CancelStatus.Cancelled => Results.Ok(result.Reservation),
                CancelStatus.NotFound => Results.Problem(statusCode: 404, title: "Reservation not found",
                    detail: "No reservation matches that confirmation code and email."),
                CancelStatus.AlreadyCancelled => Results.Problem(statusCode: 409, title: "Already cancelled"),
                _ => Results.Problem(statusCode: 409, title: "Cannot cancel",
                    detail: "Reservations can only be cancelled before the check-in date."),
            };
        });
    }
}
