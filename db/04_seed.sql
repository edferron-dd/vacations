-- Demo data. Run as VACATION in XEPDB1 after 02_schema.sql.
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET DEFINE OFF FEEDBACK OFF

INSERT INTO destinations (name, country, region, category, description, price_per_night, max_guests, rooms, rating)
VALUES ('Azure Bay Resort', 'Greece', 'Santorini', 'ISLAND',
        'Whitewashed cliffside suites above the caldera with private plunge pools, sunset dining and daily boat trips to the volcanic hot springs.',
        420, 4, 12, 4.9);
INSERT INTO destinations (name, country, region, category, description, price_per_night, max_guests, rooms, rating)
VALUES ('Alpine Lodge Zermatt', 'Switzerland', 'Valais', 'MOUNTAIN',
        'Timber chalet lodge with Matterhorn views, ski-in/ski-out access in winter and guided glacier hikes in summer. Spa and fondue cellar on site.',
        385, 6, 10, 4.8);
INSERT INTO destinations (name, country, region, category, description, price_per_night, max_guests, rooms, rating)
VALUES ('Tulum Jungle Casitas', 'Mexico', 'Quintana Roo', 'BEACH',
        'Eco-friendly casitas tucked between jungle and a white-sand beach, steps from Mayan ruins and cenotes. Yoga deck and farm-to-table restaurant.',
        210, 4, 16, 4.6);
INSERT INTO destinations (name, country, region, category, description, price_per_night, max_guests, rooms, rating)
VALUES ('Kyoto Machiya House', 'Japan', 'Kansai', 'CITY',
        'Restored wooden townhouse in the Gion district with a tatami tea room and private garden, walking distance to temples and Nishiki Market.',
        260, 4, 6, 4.9);
INSERT INTO destinations (name, country, region, category, description, price_per_night, max_guests, rooms, rating)
VALUES ('Serengeti Plains Camp', 'Tanzania', 'Mara Region', 'SAFARI',
        'Luxury tented camp on the migration route. Twice-daily game drives with expert guides, hot-air balloon safaris and bush dinners under the stars.',
        650, 3, 8, 4.9);
INSERT INTO destinations (name, country, region, category, description, price_per_night, max_guests, rooms, rating)
VALUES ('Tuscan Villa Retreat', 'Italy', 'Tuscany', 'COUNTRYSIDE',
        'Sixteenth-century farmhouse among vineyards and olive groves near Siena, with an infinity pool, cooking classes and private wine tastings.',
        310, 8, 5, 4.7);
INSERT INTO destinations (name, country, region, category, description, price_per_night, max_guests, rooms, rating)
VALUES ('Maui Sunrise Beach Club', 'United States', 'Hawaii', 'BEACH',
        'Oceanfront condos on Kaanapali Beach with snorkeling off the reef, a lagoon pool and easy access to the Road to Hana and Haleakala sunrise tours.',
        340, 6, 20, 4.5);
INSERT INTO destinations (name, country, region, category, description, price_per_night, max_guests, rooms, rating)
VALUES ('Reykjavik Northern Lights Hotel', 'Iceland', 'Capital Region', 'CITY',
        'Design hotel with a rooftop hot tub for aurora viewing, close to the harbour. Golden Circle, ice cave and Blue Lagoon excursions available.',
        230, 3, 14, 4.4);
INSERT INTO destinations (name, country, region, category, description, price_per_night, max_guests, rooms, rating)
VALUES ('Bali Rice Terrace Villas', 'Indonesia', 'Ubud', 'COUNTRYSIDE',
        'Private pool villas overlooking emerald rice terraces, with daily Balinese massage, temple tours and a riverside wellness center.',
        180, 4, 18, 4.7);
INSERT INTO destinations (name, country, region, category, description, price_per_night, max_guests, rooms, rating)
VALUES ('Maldives Overwater Bungalows', 'Maldives', 'South Male Atoll', 'ISLAND',
        'Overwater bungalows with glass floors above a turquoise lagoon. House reef snorkeling, sunset dolphin cruises and an underwater restaurant.',
        890, 3, 10, 5.0);
INSERT INTO destinations (name, country, region, category, description, price_per_night, max_guests, rooms, rating)
VALUES ('Banff Lakeside Cabins', 'Canada', 'Alberta', 'MOUNTAIN',
        'Cozy log cabins on the shore of a glacier-fed lake in the Canadian Rockies. Canoeing, wildlife spotting and the Icefields Parkway on the doorstep.',
        275, 5, 9, 4.6);
INSERT INTO destinations (name, country, region, category, description, price_per_night, max_guests, rooms, rating)
VALUES ('Lisbon Old Town Suites', 'Portugal', 'Lisbon', 'CITY',
        'Boutique suites in Alfama with river views, rooftop fado evenings and tram 28 at the door. Day trips to Sintra and the Cascais coast.',
        165, 4, 12, 4.5);

-- A few upcoming trips for the demo account demo@example.com.
INSERT INTO reservations (confirmation_code, destination_id, guest_name, guest_email, check_in, check_out, guests, total_price, source)
SELECT 'VAC-DEMO01', id, 'Demo Guest', 'demo@example.com', TRUNC(SYSDATE) + 30, TRUNC(SYSDATE) + 35, 2, price_per_night * 5, 'WEB'
  FROM destinations WHERE name = 'Azure Bay Resort';
INSERT INTO reservations (confirmation_code, destination_id, guest_name, guest_email, check_in, check_out, guests, total_price, source)
SELECT 'VAC-DEMO02', id, 'Demo Guest', 'demo@example.com', TRUNC(SYSDATE) + 60, TRUNC(SYSDATE) + 67, 4, price_per_night * 7, 'CHAT'
  FROM destinations WHERE name = 'Alpine Lodge Zermatt';

COMMIT;
