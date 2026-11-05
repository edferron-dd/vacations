using System.Diagnostics;
using System.Globalization;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Logging;

namespace Vacations.Forecast;

public sealed record DayView(DateOnly Date, int HighC, int LowC, int PrecipChance, int WeatherCode, string Summary);

public sealed record ForecastResponse(
    string Place, string Mode, DateOnly From, DateOnly To, string Summary,
    IReadOnlyList<DayView> Days, IReadOnlyList<string> Packing);

public sealed class ForecastFunction(OpenMeteoClient weather, IMemoryCache cache, ILogger<ForecastFunction> logger)
{
    const int ForecastHorizonDays = 15;   // Open-Meteo forecasts 16 days, today included
    const int MaxDays = 31;               // a 30-night stay, counting the check-out day
    const int ClimateYears = 3;
    static readonly string[] Categories = ["BEACH", "ISLAND", "MOUNTAIN", "CITY", "COUNTRYSIDE", "SAFARI"];

    /// <summary>
    /// GET /api/forecast?lat=&amp;lon=&amp;from=&amp;to=&amp;place=&amp;category= - weather for each day of a stay
    /// (check-in through check-out) plus a packing list. Within the forecast horizon it uses the live forecast,
    /// otherwise typical weather for those dates over the last few years.
    /// </summary>
    [Function("Forecast")]
    public async Task<IActionResult> Run(
        [HttpTrigger(AuthorizationLevel.Function, "get", Route = "forecast")] HttpRequest req, CancellationToken ct)
    {
        var errors = new Dictionary<string, string[]>();
        var lat = ParseDouble(req.Query["lat"], -90, 90, "lat", errors);
        var lon = ParseDouble(req.Query["lon"], -180, 180, "lon", errors);
        var from = ParseDate(req.Query["from"], "from", errors);
        var to = ParseDate(req.Query["to"], "to", errors);
        if (from is { } f && to is { } t && (t < f || t.DayNumber - f.DayNumber + 1 > MaxDays))
            errors["to"] = [$"'to' must be on or after 'from', and the range at most {MaxDays} days."];
        var place = req.Query["place"].ToString().Trim() is { Length: > 0 and <= 100 } p ? p : "Destination";
        var category = req.Query["category"].ToString().Trim().ToUpperInvariant();
        if (!Categories.Contains(category)) category = "CITY";
        if (errors.Count > 0) return new BadRequestObjectResult(new ValidationProblemDetails(errors));
        var (latitude, longitude, start, end) = (lat!.Value, lon!.Value, from!.Value, to!.Value);

        var today = DateOnly.FromDateTime(DateTime.UtcNow);
        var mode = start >= today.AddDays(-30) && end <= today.AddDays(ForecastHorizonDays) ? "forecast" : "climate";
        var request = Activity.Current;
        request?.SetTag("forecast.place", place);
        request?.SetTag("forecast.mode", mode);
        request?.SetTag("forecast.days", end.DayNumber - start.DayNumber + 1);

        // Forecasts change during the day; normals for past years don't.
        var key = string.Create(CultureInfo.InvariantCulture, $"{mode}:{latitude:F2},{longitude:F2}:{start:yyyy-MM-dd}:{end:yyyy-MM-dd}");
        var cached = cache.TryGetValue(key, out IReadOnlyList<DayWeather>? days);
        request?.SetTag("forecast.cache", cached ? "hit" : "miss");
        if (!cached)
        {
            try
            {
                days = mode == "forecast"
                    ? await weather.ForecastAsync(latitude, longitude, start, end, ct)
                    : await weather.ClimateAsync(latitude, longitude, start, end, ClimateYears, ct);
            }
            catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException && !ct.IsCancellationRequested)
            {
                logger.LogError(ex, "Open-Meteo {Mode} request failed for {Place} {From}..{To}", mode, place, start, end);
                request?.SetStatus(ActivityStatusCode.Error, "Weather provider unavailable");
                return new ObjectResult(new ProblemDetails
                {
                    Status = StatusCodes.Status502BadGateway,
                    Title = "Weather provider unavailable",
                    Detail = "Could not get weather data right now. Try again shortly.",
                }) { StatusCode = StatusCodes.Status502BadGateway };
            }
            cache.Set(key, days, mode == "forecast" ? TimeSpan.FromMinutes(30) : TimeSpan.FromHours(12));
        }
        if (mode == "climate")
            logger.LogInformation("{Place} {From}..{To} is beyond the {Horizon}-day forecast horizon; using {Years}-year climate normals",
                place, start, end, ForecastHorizonDays, ClimateYears);

        IReadOnlyList<string> packing;
        using (var span = Telemetry.Source.StartActivity("BuildPackingList"))
        {
            packing = PackingList.Build(days!, category, days!.Count - 1);
            span?.SetTag("forecast.category", category);
            span?.SetTag("packing.items", packing.Count);
        }

        Telemetry.Forecasts.Add(1,
            new KeyValuePair<string, object?>("mode", mode),
            new KeyValuePair<string, object?>("cache", cached ? "hit" : "miss"),
            new KeyValuePair<string, object?>("category", category));
        logger.LogInformation("Forecast for {Place} {From}..{To}: mode={Mode} cache={Cache} days={Days} packingItems={PackingItems}",
            place, start, end, mode, cached ? "hit" : "miss", days.Count, packing.Count);

        return new OkObjectResult(new ForecastResponse(place, mode, start, end, PackingList.Summary(days),
            days.Select(d => new DayView(d.Date, (int)Math.Round(d.HighC), (int)Math.Round(d.LowC), d.PrecipChance, d.WeatherCode,
                PackingList.Describe(d.WeatherCode))).ToList(),
            packing));
    }

    static double? ParseDouble(string? value, double min, double max, string field, Dictionary<string, string[]> errors)
    {
        if (double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var number) && number >= min && number <= max)
            return number;
        errors[field] = [$"'{field}' must be a number between {min} and {max}."];
        return null;
    }

    static DateOnly? ParseDate(string? value, string field, Dictionary<string, string[]> errors)
    {
        if (DateOnly.TryParseExact(value, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var date)) return date;
        errors[field] = [$"'{field}' must be a date in yyyy-MM-dd format."];
        return null;
    }
}
