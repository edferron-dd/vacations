namespace Vacations.Api;

// Row types are mutable classes so Dapper can map Oracle NUMBER/DATE columns onto them;
// API responses are records with DateOnly so JSON carries plain "yyyy-MM-dd" dates.

public sealed class DestinationRow
{
    public long Id { get; set; }
    public string Name { get; set; } = "";
    public string Country { get; set; } = "";
    public string Region { get; set; } = "";
    public string Category { get; set; } = "";
    public string Description { get; set; } = "";
    public decimal PricePerNight { get; set; }
    public int MaxGuests { get; set; }
    public int Rooms { get; set; }
    public decimal Rating { get; set; }
    public double? Latitude { get; set; }
    public double? Longitude { get; set; }
}

public sealed class ReservationRow
{
    public long Id { get; set; }
    public string ConfirmationCode { get; set; } = "";
    public long DestinationId { get; set; }
    public string DestinationName { get; set; } = "";
    public string Country { get; set; } = "";
    public string GuestName { get; set; } = "";
    public string GuestEmail { get; set; } = "";
    public DateTime CheckIn { get; set; }
    public DateTime CheckOut { get; set; }
    public int Guests { get; set; }
    public decimal TotalPrice { get; set; }
    public string Status { get; set; } = "";
    public string Source { get; set; } = "";
    public DateTime CreatedAt { get; set; }
    public DateTime? CancelledAt { get; set; }
}

public sealed record Quote(DateOnly CheckIn, DateOnly CheckOut, int Nights, int Guests, bool Available, int RoomsLeft, decimal TotalPrice);

public sealed record DestinationView(
    long Id, string Name, string Country, string Region, string Category, string Description,
    decimal PricePerNight, int MaxGuests, decimal Rating, Quote? Quote)
{
    public static DestinationView From(DestinationRow d, Quote? quote = null) =>
        new(d.Id, d.Name, d.Country, d.Region, d.Category, d.Description, d.PricePerNight, d.MaxGuests, d.Rating, quote);
}

public sealed record ReservationView(
    string ConfirmationCode, long DestinationId, string DestinationName, string Country,
    string GuestName, string GuestEmail, DateOnly CheckIn, DateOnly CheckOut, int Nights, int Guests,
    decimal TotalPrice, string Status, string Source, DateTime CreatedAt, DateTime? CancelledAt)
{
    public static ReservationView From(ReservationRow r)
    {
        var checkIn = DateOnly.FromDateTime(r.CheckIn);
        var checkOut = DateOnly.FromDateTime(r.CheckOut);
        return new(r.ConfirmationCode, r.DestinationId, r.DestinationName, r.Country, r.GuestName, r.GuestEmail,
            checkIn, checkOut, checkOut.DayNumber - checkIn.DayNumber, r.Guests, r.TotalPrice, r.Status, r.Source,
            r.CreatedAt, r.CancelledAt);
    }
}

public sealed record CreateReservationRequest(
    long DestinationId, string? GuestName, string? GuestEmail, DateOnly CheckIn, DateOnly CheckOut, int Guests, string? Source);

public sealed record CancelReservationRequest(string? Email);
