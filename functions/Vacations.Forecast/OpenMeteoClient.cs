using System.Globalization;
using System.Text.Json;

namespace Vacations.Forecast;

public sealed record DayWeather(DateOnly Date, double HighC, double LowC, int PrecipChance, int WeatherCode);

/// <summary>Daily weather from Open-Meteo (free, no API key): forecasts, or climate normals from past years.</summary>
public sealed class OpenMeteoClient(HttpClient http)
{
    const string ForecastUrl = "https://api.open-meteo.com/v1/forecast";
    const string ArchiveUrl = "https://archive-api.open-meteo.com/v1/archive";

    public async Task<IReadOnlyList<DayWeather>> ForecastAsync(double lat, double lon, DateOnly from, DateOnly to, CancellationToken ct)
    {
        using var doc = await GetDailyAsync(ForecastUrl, lat, lon, from, to,
            "temperature_2m_max,temperature_2m_min,precipitation_probability_max,weather_code", ct);
        var daily = doc.RootElement.GetProperty("daily");
        return Enumerable.Range(0, to.DayNumber - from.DayNumber + 1).Select(i => new DayWeather(
            from.AddDays(i),
            Value(daily, "temperature_2m_max", i),
            Value(daily, "temperature_2m_min", i),
            (int)Value(daily, "precipitation_probability_max", i),
            (int)Value(daily, "weather_code", i))).ToList();
    }

    /// <summary>
    /// Typical weather for dates beyond the forecast horizon: the same dates in each of the last
    /// <paramref name="years"/> years, fetched in parallel. Rain chance is the share of years with at least 1 mm.
    /// </summary>
    public async Task<IReadOnlyList<DayWeather>> ClimateAsync(double lat, double lon, DateOnly from, DateOnly to, int years, CancellationToken ct)
    {
        var days = to.DayNumber - from.DayNumber + 1;
        using var activity = Telemetry.Source.StartActivity("ClimateNormals");
        activity?.SetTag("forecast.years", years);

        var docs = await Task.WhenAll(Enumerable.Range(1, years).Select(y =>
        {
            var start = from.AddYears(-y);   // keep each year's range the same length, even across Feb 29
            return GetDailyAsync(ArchiveUrl, lat, lon, start, start.AddDays(days - 1),
                "temperature_2m_max,temperature_2m_min,precipitation_sum,weather_code", ct);
        }));
        try
        {
            var dailies = docs.Select(d => d.RootElement.GetProperty("daily")).ToList();
            return Enumerable.Range(0, days).Select(i => new DayWeather(
                from.AddDays(i),
                dailies.Average(d => Value(d, "temperature_2m_max", i)),
                dailies.Average(d => Value(d, "temperature_2m_min", i)),
                (int)Math.Round(100.0 * dailies.Count(d => Value(d, "precipitation_sum", i) >= 1) / dailies.Count),
                dailies.GroupBy(d => (int)Value(d, "weather_code", i)).OrderByDescending(g => g.Count()).First().Key)).ToList();
        }
        finally
        {
            foreach (var doc in docs) doc.Dispose();
        }
    }

    async Task<JsonDocument> GetDailyAsync(string baseUrl, double lat, double lon, DateOnly from, DateOnly to, string fields, CancellationToken ct)
    {
        var url = string.Create(CultureInfo.InvariantCulture,
            $"{baseUrl}?latitude={lat:F4}&longitude={lon:F4}&daily={fields}&timezone=auto&start_date={from:yyyy-MM-dd}&end_date={to:yyyy-MM-dd}");
        using var response = await http.GetAsync(url, ct);
        response.EnsureSuccessStatusCode();
        await using var stream = await response.Content.ReadAsStreamAsync(ct);
        return await JsonDocument.ParseAsync(stream, cancellationToken: ct);
    }

    static double Value(JsonElement daily, string field, int index)
    {
        var values = daily.GetProperty(field);
        return index < values.GetArrayLength() && values[index].ValueKind == JsonValueKind.Number ? values[index].GetDouble() : 0;
    }
}
