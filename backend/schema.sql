-- ServeNext - Token & Queue Management System : PostgreSQL schema
-- Idempotent: safe to run many times. The Go backend applies it on startup,
-- or run manually:  psql "$DATABASE_URL" -f backend/schema.sql

CREATE TABLE IF NOT EXISTS departments (
    id                      SERIAL PRIMARY KEY,
    code                    VARCHAR(5) NOT NULL UNIQUE,         -- IT, HR, ACC, ADM
    name                    TEXT       NOT NULL,
    is_paused               BOOLEAN    NOT NULL DEFAULT FALSE,
    last_seq                INT        NOT NULL DEFAULT 0,      -- counter used for IT-001, IT-002 ...
    default_service_minutes INT        NOT NULL DEFAULT 5       -- fallback until real averages exist
);

CREATE TABLE IF NOT EXISTS staff (
    id            SERIAL PRIMARY KEY,
    username      TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,                                -- salt$pbkdf2-sha256
    full_name     TEXT NOT NULL,
    role          TEXT NOT NULL CHECK (role IN ('admin', 'staff')),
    department_id INT REFERENCES departments(id)                -- NULL for admin (all departments)
);

CREATE TABLE IF NOT EXISTS tokens (
    id               SERIAL PRIMARY KEY,
    token_number     TEXT NOT NULL UNIQUE,                      -- IT-001
    department_id    INT  NOT NULL REFERENCES departments(id),
    visitor_name     TEXT NOT NULL,
    visitor_phone    TEXT NOT NULL DEFAULT '',
    priority         INT  NOT NULL DEFAULT 0,                   -- 1 = priority token
    status           TEXT NOT NULL CHECK (status IN ('waiting', 'serving', 'completed', 'cancelled')),
    cancel_reason    TEXT,                                      -- cancelled_by_visitor | no_show_twice
    no_show_count    INT  NOT NULL DEFAULT 0,
    transferred_from TEXT,                                      -- previous token number if transferred
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    queue_time       TIMESTAMPTZ NOT NULL DEFAULT now(),        -- ordering key; reset on no-show / transfer
    called_at        TIMESTAMPTZ,
    completed_at     TIMESTAMPTZ,
    served_by        INT REFERENCES staff(id)
);

-- Fast queue lookups, in the exact order the queue is served.
CREATE INDEX IF NOT EXISTS idx_tokens_queue
    ON tokens (department_id, status, priority DESC, queue_time, id);

-- A department can serve only ONE token at a time (enforced by the database).
CREATE UNIQUE INDEX IF NOT EXISTS uq_one_serving_per_department
    ON tokens (department_id) WHERE status = 'serving';

-- Audit trail (also used for the "no-shows" dashboard counter).
CREATE TABLE IF NOT EXISTS token_events (
    id            BIGSERIAL PRIMARY KEY,
    token_id      INT  NOT NULL REFERENCES tokens(id),
    department_id INT  NOT NULL REFERENCES departments(id),
    event         TEXT NOT NULL,   -- created|called|completed|no_show|cancelled|transferred|priority_on|priority_off
    staff_id      INT REFERENCES staff(id),
    detail        TEXT NOT NULL DEFAULT '',
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_events_dept_time ON token_events (department_id, event, created_at);

-- Seed departments (staff users are seeded by the backend because it hashes passwords).
INSERT INTO departments (code, name) VALUES
    ('IT',  'IT Support'),
    ('HR',  'HR'),
    ('ACC', 'Accounts'),
    ('ADM', 'Administration')
ON CONFLICT (code) DO NOTHING;
