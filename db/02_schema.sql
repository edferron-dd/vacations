-- Application tables. Run as VACATION in XEPDB1.
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET FEEDBACK OFF

CREATE TABLE destinations (
  id              NUMBER GENERATED ALWAYS AS IDENTITY
                  CONSTRAINT destinations_pk PRIMARY KEY,
  name            VARCHAR2(100)  NOT NULL CONSTRAINT destinations_name_uk UNIQUE,
  country         VARCHAR2(60)   NOT NULL,
  region          VARCHAR2(60)   NOT NULL,
  category        VARCHAR2(20)   NOT NULL
                  CONSTRAINT destinations_category_ck
                  CHECK (category IN ('BEACH', 'MOUNTAIN', 'CITY', 'ISLAND', 'SAFARI', 'COUNTRYSIDE')),
  description     VARCHAR2(1000) NOT NULL,
  price_per_night NUMBER(10,2)   NOT NULL CONSTRAINT destinations_price_ck CHECK (price_per_night > 0),
  max_guests      NUMBER(2)      NOT NULL CONSTRAINT destinations_max_guests_ck CHECK (max_guests BETWEEN 1 AND 20),
  -- Units bookable per night; each reservation occupies one unit for every night of its stay.
  rooms           NUMBER(4)      NOT NULL CONSTRAINT destinations_rooms_ck CHECK (rooms >= 0),
  rating          NUMBER(2,1)    NOT NULL CONSTRAINT destinations_rating_ck CHECK (rating BETWEEN 0 AND 5)
);

CREATE TABLE reservations (
  id                NUMBER GENERATED ALWAYS AS IDENTITY
                    CONSTRAINT reservations_pk PRIMARY KEY,
  confirmation_code VARCHAR2(12)  NOT NULL CONSTRAINT reservations_code_uk UNIQUE,
  destination_id    NUMBER        NOT NULL
                    CONSTRAINT reservations_destination_fk REFERENCES destinations (id),
  guest_name        VARCHAR2(100) NOT NULL,
  guest_email       VARCHAR2(254) NOT NULL,
  check_in          DATE          NOT NULL,
  check_out         DATE          NOT NULL,
  guests            NUMBER(2)     NOT NULL CONSTRAINT reservations_guests_ck CHECK (guests >= 1),
  total_price       NUMBER(12,2)  NOT NULL CONSTRAINT reservations_total_ck CHECK (total_price >= 0),
  status            VARCHAR2(10)  DEFAULT 'CONFIRMED' NOT NULL
                    CONSTRAINT reservations_status_ck CHECK (status IN ('CONFIRMED', 'CANCELLED')),
  source            VARCHAR2(10)  DEFAULT 'WEB' NOT NULL
                    CONSTRAINT reservations_source_ck CHECK (source IN ('WEB', 'CHAT')),
  created_at        TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
  cancelled_at      TIMESTAMP,
  CONSTRAINT reservations_dates_ck CHECK (check_out > check_in)
);

CREATE INDEX reservations_availability_ix ON reservations (destination_id, status, check_in, check_out);
CREATE INDEX reservations_email_ix ON reservations (LOWER(guest_email));
