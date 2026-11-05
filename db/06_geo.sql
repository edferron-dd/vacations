-- Destination coordinates, used for trip weather forecasts. Run as VACATION in XEPDB1.
-- Idempotent, so setup-db.ps1 runs it on every invocation (also upgrades schemas created before it existed).
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET FEEDBACK OFF

DECLARE
  l_count NUMBER;
BEGIN
  SELECT COUNT(*) INTO l_count FROM user_tab_columns WHERE table_name = 'DESTINATIONS' AND column_name = 'LATITUDE';
  IF l_count = 0 THEN
    EXECUTE IMMEDIATE q'[
      ALTER TABLE destinations ADD (
        latitude  NUMBER(8,5) CONSTRAINT destinations_latitude_ck CHECK (latitude BETWEEN -90 AND 90),
        longitude NUMBER(8,5) CONSTRAINT destinations_longitude_ck CHECK (longitude BETWEEN -180 AND 180)
      )]';
  END IF;
END;
/

-- Seed destinations only; rows added later keep whatever coordinates they were given.
UPDATE destinations d
   SET (latitude, longitude) = (
         SELECT g.lat, g.lon FROM (
           SELECT 'Azure Bay Resort' name, 36.39 lat, 25.46 lon FROM dual UNION ALL
           SELECT 'Alpine Lodge Zermatt', 46.02, 7.75 FROM dual UNION ALL
           SELECT 'Tulum Jungle Casitas', 20.21, -87.47 FROM dual UNION ALL
           SELECT 'Kyoto Machiya House', 35.01, 135.77 FROM dual UNION ALL
           SELECT 'Serengeti Plains Camp', -2.33, 34.83 FROM dual UNION ALL
           SELECT 'Tuscan Villa Retreat', 43.32, 11.33 FROM dual UNION ALL
           SELECT 'Maui Sunrise Beach Club', 20.76, -156.46 FROM dual UNION ALL
           SELECT 'Reykjavik Northern Lights Hotel', 64.15, -21.94 FROM dual UNION ALL
           SELECT 'Bali Rice Terrace Villas', -8.51, 115.26 FROM dual UNION ALL
           SELECT 'Maldives Overwater Bungalows', 3.95, 73.48 FROM dual UNION ALL
           SELECT 'Banff Lakeside Cabins', 51.18, -115.57 FROM dual UNION ALL
           SELECT 'Lisbon Old Town Suites', 38.71, -9.14 FROM dual
         ) g WHERE g.name = d.name)
 WHERE d.latitude IS NULL
   AND d.name IN ('Azure Bay Resort', 'Alpine Lodge Zermatt', 'Tulum Jungle Casitas', 'Kyoto Machiya House',
                  'Serengeti Plains Camp', 'Tuscan Villa Retreat', 'Maui Sunrise Beach Club',
                  'Reykjavik Northern Lights Hotel', 'Bali Rice Terrace Villas', 'Maldives Overwater Bungalows',
                  'Banff Lakeside Cabins', 'Lisbon Old Town Suites');
COMMIT;
