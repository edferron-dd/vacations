using System.Data;
using System.Security.Cryptography;
using System.Text;
using Dapper;
using Oracle.ManagedDataAccess.Client;

namespace Vacations.Api;

public enum BookingStatus { Created, DestinationNotFound, TooManyGuests, SoldOut }

public sealed record BookingResult(BookingStatus Status, ReservationView? Reservation = null, int MaxGuests = 0);

public enum CancelStatus { Cancelled, NotFound, AlreadyCancelled, AlreadyStarted }

public sealed record CancelResult(CancelStatus Status, ReservationView? Reservation = null);

/// <summary>Oracle data access plus the booking rules that need a transaction (availability, overbooking).</summary>
public sealed class VacationStore(IConfiguration config)
{
    const string DestinationColumns =
        "id, name, country, region, category, description, price_per_night, max_guests, rooms, rating, latitude, longitude";

    const string ReservationSelect = """
        SELECT r.id, r.confirmation_code, r.destination_id, d.name AS destination_name, d.country,
               r.guest_name, r.guest_email, r.check_in, r.check_out, r.guests, r.total_price,
               r.status, r.source, r.created_at, r.cancelled_at
          FROM reservations r
          JOIN destinations d ON d.id = r.destination_id
        """;

    static VacationStore() => DefaultTypeMap.MatchNamesWithUnderscores = true;

    sealed class StayRow
    {
        public long DestinationId { get; set; }
        public DateTime CheckIn { get; set; }
        public DateTime CheckOut { get; set; }
    }

    async Task<OracleConnection> OpenAsync()
    {
        var connectionString = config.GetConnectionString("Oracle");
        if (string.IsNullOrWhiteSpace(connectionString))
            throw new InvalidOperationException(
                "ConnectionStrings:Oracle is not configured. Set the ConnectionStrings__Oracle environment variable.");
        var connection = new OracleConnection(connectionString);
        await connection.OpenAsync();
        return connection;
    }

    public async Task PingAsync()
    {
        await using var connection = await OpenAsync();
        await connection.ExecuteScalarAsync<int>("SELECT 1 FROM dual");
    }

    public async Task<IReadOnlyList<DestinationRow>> SearchAsync(string? query, string? category, decimal? maxPrice, int? guests)
    {
        var sql = new StringBuilder($"SELECT {DestinationColumns} FROM destinations WHERE 1 = 1");
        var parameters = new DynamicParameters();

        // Every search word must match at least one descriptive column, so "beach mexico" narrows results.
        var words = (query ?? "").Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).Take(5);
        var i = 0;
        foreach (var word in words)
        {
            var name = $"w{i++}";
            sql.Append($" AND (UPPER(name) LIKE :{name} OR UPPER(country) LIKE :{name} OR UPPER(region) LIKE :{name}" +
                       $" OR UPPER(category) LIKE :{name} OR UPPER(description) LIKE :{name})");
            parameters.Add(name, $"%{word.ToUpperInvariant()}%");
        }
        if (!string.IsNullOrWhiteSpace(category))
        {
            sql.Append(" AND category = :category");
            parameters.Add("category", category.Trim().ToUpperInvariant());
        }
        if (maxPrice is not null)
        {
            sql.Append(" AND price_per_night <= :maxPrice");
            parameters.Add("maxPrice", maxPrice);
        }
        if (guests is not null)
        {
            sql.Append(" AND max_guests >= :guests");
            parameters.Add("guests", guests);
        }
        sql.Append(" ORDER BY rating DESC, name");

        await using var connection = await OpenAsync();
        return (await connection.QueryAsync<DestinationRow>(sql.ToString(), parameters)).AsList();
    }

    public async Task<DestinationRow?> GetDestinationAsync(long id)
    {
        await using var connection = await OpenAsync();
        return await connection.QuerySingleOrDefaultAsync<DestinationRow>(
            $"SELECT {DestinationColumns} FROM destinations WHERE id = :id", new { id });
    }

    /// <summary>Quotes a stay for each destination: rooms left is total rooms minus the busiest night's bookings.</summary>
    public async Task<Dictionary<long, Quote>> QuoteAsync(IReadOnlyCollection<DestinationRow> destinations, DateOnly checkIn, DateOnly checkOut, int guests)
    {
        await using var connection = await OpenAsync();
        var peak = await PeakOccupancyAsync(connection, null, checkIn, checkOut, destinations.Count == 1 ? destinations.First().Id : null);
        return destinations.ToDictionary(d => d.Id, d => BuildQuote(d, checkIn, checkOut, guests, peak.GetValueOrDefault(d.Id)));
    }

    static Quote BuildQuote(DestinationRow d, DateOnly checkIn, DateOnly checkOut, int guests, int booked)
    {
        var nights = checkOut.DayNumber - checkIn.DayNumber;
        var roomsLeft = Math.Max(0, d.Rooms - booked);
        return new Quote(checkIn, checkOut, nights, guests, roomsLeft > 0 && guests <= d.MaxGuests, roomsLeft, d.PricePerNight * nights);
    }

    static async Task<Dictionary<long, int>> PeakOccupancyAsync(
        IDbConnection connection, IDbTransaction? transaction, DateOnly checkIn, DateOnly checkOut, long? destinationId)
    {
        var sql = "SELECT destination_id, check_in, check_out FROM reservations " +
                  "WHERE status = 'CONFIRMED' AND check_in < :checkOut AND check_out > :checkIn";
        var parameters = new DynamicParameters(new
        {
            checkIn = checkIn.ToDateTime(TimeOnly.MinValue),
            checkOut = checkOut.ToDateTime(TimeOnly.MinValue),
        });
        // Oracle rejects bind variables that aren't in the statement (ORA-01036), so only add it when used.
        if (destinationId is not null)
        {
            sql += " AND destination_id = :destinationId";
            parameters.Add("destinationId", destinationId);
        }

        var stays = await connection.QueryAsync<StayRow>(sql, parameters, transaction);

        var peak = new Dictionary<long, int>();
        foreach (var group in stays.GroupBy(s => s.DestinationId))
        {
            var max = 0;
            for (var night = checkIn; night < checkOut; night = night.AddDays(1))
            {
                var at = night.ToDateTime(TimeOnly.MinValue);
                max = Math.Max(max, group.Count(s => s.CheckIn <= at && s.CheckOut > at));
            }
            peak[group.Key] = max;
        }
        return peak;
    }

    public async Task<BookingResult> CreateReservationAsync(
        long destinationId, string guestName, string guestEmail, DateOnly checkIn, DateOnly checkOut, int guests, string source)
    {
        await using var connection = await OpenAsync();
        await using var transaction = await connection.BeginTransactionAsync();

        // Locking the destination row serializes concurrent bookings for it, so two guests can't take the last room.
        var destination = await connection.QuerySingleOrDefaultAsync<DestinationRow>(
            $"SELECT {DestinationColumns} FROM destinations WHERE id = :id FOR UPDATE", new { id = destinationId }, transaction);
        if (destination is null) return new(BookingStatus.DestinationNotFound);
        if (guests > destination.MaxGuests) return new(BookingStatus.TooManyGuests, MaxGuests: destination.MaxGuests);

        var peak = await PeakOccupancyAsync(connection, transaction, checkIn, checkOut, destination.Id);
        var quote = BuildQuote(destination, checkIn, checkOut, guests, peak.GetValueOrDefault(destination.Id));
        if (quote.RoomsLeft == 0) return new(BookingStatus.SoldOut);

        string code;
        for (var attempt = 1; ; attempt++)
        {
            code = NewConfirmationCode();
            try
            {
                await connection.ExecuteAsync("""
                    INSERT INTO reservations
                      (confirmation_code, destination_id, guest_name, guest_email, check_in, check_out, guests, total_price, source)
                    VALUES (:code, :destinationId, :guestName, :guestEmail, :checkIn, :checkOut, :guests, :totalPrice, :source)
                    """,
                    new
                    {
                        code, destinationId, guestName, guestEmail,
                        checkIn = checkIn.ToDateTime(TimeOnly.MinValue),
                        checkOut = checkOut.ToDateTime(TimeOnly.MinValue),
                        guests, totalPrice = quote.TotalPrice, source,
                    }, transaction);
                break;
            }
            catch (OracleException ex) when (ex.Number == 1 && attempt < 3) // ORA-00001: confirmation code collision
            {
            }
        }

        await transaction.CommitAsync();
        var row = await connection.QuerySingleAsync<ReservationRow>(
            $"{ReservationSelect} WHERE r.confirmation_code = :code", new { code });
        return new(BookingStatus.Created, ReservationView.From(row));
    }

    public async Task<ReservationView?> GetReservationAsync(string code, string email)
    {
        await using var connection = await OpenAsync();
        var row = await connection.QuerySingleOrDefaultAsync<ReservationRow>(
            $"{ReservationSelect} WHERE r.confirmation_code = :code AND LOWER(r.guest_email) = :email",
            new { code = code.Trim().ToUpperInvariant(), email });
        return row is null ? null : ReservationView.From(row);
    }

    public async Task<IReadOnlyList<ReservationView>> ListReservationsAsync(string email)
    {
        await using var connection = await OpenAsync();
        var rows = await connection.QueryAsync<ReservationRow>(
            $"{ReservationSelect} WHERE LOWER(r.guest_email) = :email ORDER BY r.check_in DESC", new { email });
        return rows.Select(ReservationView.From).ToList();
    }

    public async Task<CancelResult> CancelReservationAsync(string code, string email, DateOnly today)
    {
        code = code.Trim().ToUpperInvariant();
        await using var connection = await OpenAsync();
        await using var transaction = await connection.BeginTransactionAsync();

        var row = await connection.QuerySingleOrDefaultAsync<ReservationRow>(
            "SELECT id, status, check_in FROM reservations WHERE confirmation_code = :code AND LOWER(guest_email) = :email FOR UPDATE",
            new { code, email }, transaction);
        if (row is null) return new(CancelStatus.NotFound);
        if (row.Status == "CANCELLED") return new(CancelStatus.AlreadyCancelled);
        if (DateOnly.FromDateTime(row.CheckIn) <= today) return new(CancelStatus.AlreadyStarted);

        await connection.ExecuteAsync(
            "UPDATE reservations SET status = 'CANCELLED', cancelled_at = SYSTIMESTAMP WHERE id = :id", new { id = row.Id }, transaction);
        await transaction.CommitAsync();

        var updated = await connection.QuerySingleAsync<ReservationRow>($"{ReservationSelect} WHERE r.id = :id", new { id = row.Id });
        return new(CancelStatus.Cancelled, ReservationView.From(updated));
    }

    static string NewConfirmationCode()
    {
        const string alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // no 0/O or 1/I lookalikes
        return "VAC-" + RandomNumberGenerator.GetString(alphabet, 6);
    }
}
