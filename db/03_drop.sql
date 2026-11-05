-- Drops the application tables (used by setup-db.ps1 -Reset). Run as VACATION in XEPDB1.
SET FEEDBACK OFF

BEGIN
  FOR t IN (SELECT table_name FROM user_tables WHERE table_name IN ('CHAT_SESSIONS', 'RESERVATIONS', 'DESTINATIONS')
            ORDER BY CASE table_name WHEN 'RESERVATIONS' THEN 1 ELSE 2 END) LOOP
    EXECUTE IMMEDIATE 'DROP TABLE ' || t.table_name || ' CASCADE CONSTRAINTS PURGE';
  END LOOP;
END;
/
