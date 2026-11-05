-- Creates (or re-keys) the VACATION application schema owner.
-- Run as SYS in the XEPDB1 pluggable database. Expects the substitution variable
-- app_password to be DEFINEd by the caller (setup-db.ps1 pipes it via stdin so it
-- never appears on a command line).
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET VERIFY OFF FEEDBACK OFF

DECLARE
  l_count NUMBER;
BEGIN
  SELECT COUNT(*) INTO l_count FROM dba_users WHERE username = 'VACATION';
  IF l_count = 0 THEN
    EXECUTE IMMEDIATE 'CREATE USER vacation IDENTIFIED BY "&app_password" '
                   || 'DEFAULT TABLESPACE users QUOTA UNLIMITED ON users';
  ELSE
    EXECUTE IMMEDIATE 'ALTER USER vacation IDENTIFIED BY "&app_password" ACCOUNT UNLOCK';
  END IF;
END;
/

GRANT CREATE SESSION, CREATE TABLE, CREATE SEQUENCE, CREATE VIEW TO vacation;
