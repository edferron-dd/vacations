using System.Net.Mail;

namespace Vacations.Api;

/// <summary>Collects field errors in the shape Results.ValidationProblem expects.</summary>
public sealed class Validation
{
    public const int MaxNights = 30;
    public const int MaxMonthsAhead = 18;

    readonly Dictionary<string, List<string>> _errors = new(StringComparer.OrdinalIgnoreCase);

    public static DateOnly Today => DateOnly.FromDateTime(DateTime.Now);

    public bool IsValid => _errors.Count == 0;

    public Dictionary<string, string[]> Errors => _errors.ToDictionary(e => e.Key, e => e.Value.ToArray());

    public void Add(string field, string message)
    {
        if (!_errors.TryGetValue(field, out var list)) _errors[field] = list = [];
        list.Add(message);
    }

    public void Stay(DateOnly checkIn, DateOnly checkOut)
    {
        var today = Today;
        if (checkIn < today) Add("checkIn", "Check-in date cannot be in the past.");
        if (checkIn > today.AddMonths(MaxMonthsAhead)) Add("checkIn", $"Bookings open at most {MaxMonthsAhead} months ahead.");
        if (checkOut <= checkIn) Add("checkOut", "Check-out must be after check-in.");
        else if (checkOut.DayNumber - checkIn.DayNumber > MaxNights) Add("checkOut", $"Stays are limited to {MaxNights} nights.");
    }

    public void Guests(int guests)
    {
        if (guests < 1) Add("guests", "At least one guest is required.");
        if (guests > 20) Add("guests", "At most 20 guests per booking.");
    }

    /// <summary>Returns the trimmed, lower-cased email, or null (with an error recorded) if it isn't valid.</summary>
    public string? Email(string? email, string field = "guestEmail")
    {
        var value = email?.Trim().ToLowerInvariant() ?? "";
        if (value.Length is 0 or > 254 || !MailAddress.TryCreate(value, out var parsed) || parsed.Address != value)
        {
            Add(field, "A valid email address is required.");
            return null;
        }
        return value;
    }

    public string? Name(string? name)
    {
        var value = name?.Trim() ?? "";
        if (value.Length < 2 || value.Length > 100)
        {
            Add("guestName", "Guest name must be between 2 and 100 characters.");
            return null;
        }
        return value;
    }
}
