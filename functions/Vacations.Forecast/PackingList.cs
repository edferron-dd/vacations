namespace Vacations.Forecast;

public static class PackingList
{
    /// <summary>Short text for a WMO weather code as returned by Open-Meteo.</summary>
    public static string Describe(int code) => code switch
    {
        0 => "Clear",
        1 or 2 => "Partly cloudy",
        3 => "Overcast",
        45 or 48 => "Fog",
        >= 51 and <= 57 => "Drizzle",
        >= 61 and <= 67 => "Rain",
        >= 71 and <= 77 => "Snow",
        >= 80 and <= 82 => "Showers",
        85 or 86 => "Snow showers",
        >= 95 => "Thunderstorms",
        _ => "Mixed",
    };

    static bool IsSnow(int code) => code is (>= 71 and <= 77) or 85 or 86;
    static bool IsWet(DayWeather d) => d.PrecipChance >= 40 || d.WeatherCode is (>= 51 and <= 67) or (>= 80 and <= 82) or >= 95;

    public static string Summary(IReadOnlyList<DayWeather> days)
    {
        var highs = days.Select(d => (int)Math.Round(d.HighC)).ToList();
        var lows = days.Select(d => (int)Math.Round(d.LowC)).ToList();
        var snow = days.Count(d => IsSnow(d.WeatherCode));
        var rain = days.Count(d => IsWet(d) && !IsSnow(d.WeatherCode));
        var outlook = (rain, snow) switch
        {
            (0, 0) => "mostly dry",
            (_, 0) => $"rain likely on {rain} of {days.Count} days",
            (0, _) => $"snow likely on {snow} of {days.Count} days",
            _ => $"rain or snow likely on {rain + snow} of {days.Count} days",
        };
        return $"Highs {Range(highs)} °C, lows {Range(lows)} °C, {outlook}.";

        // "to" rather than an en dash, which reads badly between negative numbers ("-6–-3").
        static string Range(List<int> values) => values.Min() == values.Max() ? $"{values.Min()}" : $"{values.Min()} to {values.Max()}";
    }

    public static IReadOnlyList<string> Build(IReadOnlyList<DayWeather> days, string category, int nights)
    {
        var maxHigh = days.Max(d => d.HighC);
        var minLow = days.Min(d => d.LowC);
        var beach = category is "BEACH" or "ISLAND";
        var items = new List<string> { $"Clothes for {Math.Max(nights, 1)} days" };

        if (maxHigh >= 27) items.AddRange(["Light, breathable clothing", beach ? "Reef-safe sunscreen" : "Sunscreen (SPF 30+)", "Sunglasses and a sun hat", "Reusable water bottle"]);
        else if (maxHigh >= 15) items.Add("Light layers for cooler evenings");
        if (minLow <= 5) items.AddRange(["Warm jacket (fleece or down)", "Hat and gloves"]);
        if (minLow <= 0) items.Add("Thermal base layers");
        if (days.Any(d => IsWet(d) && !IsSnow(d.WeatherCode))) items.Add("Compact umbrella or rain jacket");
        if (days.Any(d => IsSnow(d.WeatherCode))) items.Add("Waterproof boots");

        items.AddRange(category switch
        {
            "BEACH" or "ISLAND" => ["Swimwear", "Sandals", "Beach cover-up"],
            "MOUNTAIN" => ["Hiking boots", "Daypack"],
            "CITY" => ["Comfortable walking shoes"],
            "SAFARI" => ["Neutral-coloured clothing", "Binoculars", "Insect repellent"],
            "COUNTRYSIDE" => maxHigh >= 20 ? ["Comfortable walking shoes", "Insect repellent"] : ["Comfortable walking shoes"],
            _ => [],
        });
        if (beach && maxHigh >= 24) items.Add("Insect repellent");
        return items.Distinct().ToList();
    }
}
