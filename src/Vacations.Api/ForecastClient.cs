using System.Globalization;

namespace Vacations.Api;

/// <summary>
/// Calls the trip-forecast Azure Function. Configured by Forecast:BaseUrl and Forecast:FunctionKey
/// (on IIS, the app pool's Forecast__BaseUrl / Forecast__FunctionKey environment variables).
/// </summary>
public sealed class ForecastClient(HttpClient http)
{
    public bool IsConfigured => http.BaseAddress is not null;

    public Task<HttpResponseMessage> GetAsync(DestinationRow destination, DateOnly from, DateOnly to, CancellationToken ct)
    {
        var query = string.Create(CultureInfo.InvariantCulture,
            $"api/forecast?lat={destination.Latitude}&lon={destination.Longitude}&from={from:yyyy-MM-dd}&to={to:yyyy-MM-dd}" +
            $"&category={destination.Category}&place={Uri.EscapeDataString($"{destination.Region}, {destination.Country}")}");
        return http.GetAsync(query, ct);
    }
}
