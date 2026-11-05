-- Chatbot conversation history (one row per chat session). Run as VACATION in XEPDB1.
-- Idempotent, so setup-db.ps1 runs it on every invocation (also upgrades schemas created before it existed).
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET FEEDBACK OFF

DECLARE
  l_count NUMBER;
BEGIN
  SELECT COUNT(*) INTO l_count FROM user_tables WHERE table_name = 'CHAT_SESSIONS';
  IF l_count = 0 THEN
    EXECUTE IMMEDIATE q'[
      CREATE TABLE chat_sessions (
        session_id VARCHAR2(32) CONSTRAINT chat_sessions_pk PRIMARY KEY,
        -- Claude Messages API history (user/assistant turns incl. tool calls), as a JSON array.
        history    CLOB         NOT NULL CONSTRAINT chat_sessions_history_json CHECK (history IS JSON),
        created_at TIMESTAMP    DEFAULT SYSTIMESTAMP NOT NULL,
        updated_at TIMESTAMP    DEFAULT SYSTIMESTAMP NOT NULL
      )]';
    EXECUTE IMMEDIATE 'CREATE INDEX chat_sessions_updated_ix ON chat_sessions (updated_at)';
  END IF;
END;
/
