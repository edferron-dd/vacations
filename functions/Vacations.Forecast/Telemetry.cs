using System.Diagnostics;
using System.Diagnostics.Metrics;

namespace Vacations.Forecast;

public static class Telemetry
{
    public const string SourceName = "Vacations.Forecast";
    public const string MeterName = "Vacations.Forecast";

    public static readonly ActivitySource Source = new(SourceName);
    static readonly Meter Meter = new(MeterName);

    /// <summary>Forecast requests, tagged with mode (forecast/climate), cache (hit/miss) and destination category.</summary>
    public static readonly Counter<long> Forecasts = Meter.CreateCounter<long>(
        "forecast.requests", description: "Trip forecasts served");
}
