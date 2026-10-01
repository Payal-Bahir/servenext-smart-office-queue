# ServeNext - Token & Queue Management System

Visitors pick a service (IT Support, HR, Accounts, Administration), receive a unique token such as `IT-001`,
and watch their live queue position and estimated waiting time. Staff log in, run department-wise queues
and see a live dashboard.

| Layer    | Tech                                   |
|----------|----------------------------------------|
| Frontend | Flutter (Material 3) - Android, iOS, Web, Windows/macOS/Linux |
| Backend  | Go 1.22 (standard library `net/http`) + `lib/pq` |
| Database | PostgreSQL 16                          |

```
servenext/
├── backend/           Go REST API (main.go, auth.go, queue.go, handlers.go, schema.sql, Dockerfile)
├── frontend/          Flutter app (lib/main.dart, api.dart, screens/*)
├── scripts/           api_smoke_test.sh  - end-to-end check of the queue rules
├── docs/              put screenshots / demo video here
└── docker-compose.yml PostgreSQL + API with one command
```

## 1. Quick start

### Prerequisites
* Docker Desktop **or** (Go 1.22+ and PostgreSQL 14+)
* Flutter SDK 3.22+ (`flutter doctor` should be green for the platform you target)

### A. Backend + database (Docker - easiest)
```bash
docker compose up --build
# API  -> http://localhost:8080      DB -> localhost:5432 (user/pass/db: queue/queue/queuedb)
curl http://localhost:8080/api/health     # {"status":"ok"}
```
The API creates all tables, seeds the 4 departments and the demo staff accounts automatically on startup.

### A (alternative). Backend without Docker
```bash
# 1. create the database
psql -U postgres -c "CREATE USER queue WITH PASSWORD 'queue';" -c "CREATE DATABASE queuedb OWNER queue;"
# 2. run the API (applies backend/schema.sql itself)
cd backend
go mod tidy
export DATABASE_URL="postgres://queue:queue@localhost:5432/queuedb?sslmode=disable"
go run .
```
Optional env vars: `PORT` (8080), `AUTH_SECRET` (session signing key - change in production).
To load the schema manually: `psql "$DATABASE_URL" -f backend/schema.sql`.

### B. Flutter app
```bash
cd frontend
flutter create . --project-name serve_next --platforms=android,web,windows   # one-time: generates platform folders, keeps lib/
flutter pub get
flutter run -d chrome                 # Web
flutter run                           # Android emulator / device
```
API address handling:
* Web / desktop / iOS simulator -> `http://localhost:8080` (default)
* Android emulator -> `http://10.0.2.2:8080` (automatic)
* Physical phone -> `flutter run --dart-define=API_BASE_URL=http://<your-PC-LAN-IP>:8080`

Android release builds need the `INTERNET` permission in `android/app/src/main/AndroidManifest.xml`
(and `android:usesCleartextTraffic="true"` if you use plain http).

### Demo accounts
| Username | Password | Access |
|----------|----------|--------|
| `admin` | `admin123` | all departments |
| `it.staff` / `hr.staff` / `acc.staff` / `adm.staff` | `staff123` | own department only |

## 2. Feature checklist

| Requirement | Where |
|---|---|
| Visitor token generation | `POST /api/tokens`, `visitor_home.dart` |
| Services: IT Support, HR, Accounts, Administration | `departments` table (seeded) |
| Unique numbers `IT-001`, `HR-002`... | per-department counter `departments.last_seq`, incremented atomically; `token_number` is UNIQUE |
| Live queue position | computed in SQL on every request; app polls every 3 s |
| Estimated waiting time | people ahead x avg service time (last 20 completions, else 5 min default) + remaining time of current token |
| Token cancellation | `POST /api/tokens/{id}/cancel` (waiting tokens only) |
| Admin / staff login | `POST /api/auth/login`, PBKDF2-hashed passwords, HMAC-signed 12 h session token |
| Department-wise queues | every query is scoped by `department_id`; staff are limited to their own department |
| Call next / Complete / No show | `call-next`, `complete`, `no-show` endpoints + staff console buttons |
| Transfer to another department | `POST /api/admin/tokens/{id}/transfer` |
| Pause / resume department | `POST /api/admin/departments/{id}/pause` |
| Priority tokens | `POST /api/admin/tokens/{id}/priority` (star button) |
| Dashboard | waiting, serving, completed, no-shows, average waiting time (today, per department + totals) |

## 3. Special logic - how it is implemented

* **Ordering** - waiting tokens are sorted by `priority DESC, queue_time ASC, id ASC`.
* **Priority never interrupts** - priority only reorders *waiting* tokens. A department serves one token at a time
  (a partial unique index `uq_one_serving_per_department` enforces it in the DB), and "Call next" is rejected
  while someone is being served. Priority can't be applied to a serving token.
* **First no-show** - token goes back to `waiting` with `queue_time = now()` -> **end of the queue**.
* **Second no-show** - token is set to `cancelled` with reason `no_show_twice`.
* **Paused department** - `UPDATE departments ... WHERE is_paused = FALSE RETURNING` inside the token-creation
  transaction, so no token can slip through a pause (race-free). Pausing also blocks "Call next";
  waiting tokens keep their place. Transfers into a paused department are rejected.
* **Live position / ETA** - nothing is cached. Position and ETA are derived from the current queue on each
  request, so any change (call, cancel, no-show, priority, transfer) is reflected on the next poll (<= 3 s).
* **Concurrency** - token creation, call-next, no-show etc. run in transactions with row locks
  (`FOR UPDATE`, `SKIP LOCKED`), so two staff clicking at once cannot serve the same token.

### Assumptions (easy to change)
1. A **priority token loses its priority after a no-show** so that it really goes to the end of the queue.
2. **Priority is assigned by staff** (star button) - e.g. elderly / urgent visitors - not self-selected by visitors.
3. A **transferred token gets a new number** from the target department (e.g. `IT-002` -> `ACC-001`), joins the end
   of that queue, and shows `from IT-002`.
4. A department serves **one token at a time** (single counter per department).
5. Dashboard figures are for **today** (database server time zone). "Avg waiting time" = created -> called.
6. Real-time updates use **3 s polling** (simple and robust). WebSocket/SSE would be the next upgrade.

## 4. REST API

Public
| Method | Path | Body |
|---|---|---|
| GET | `/api/departments` | - |
| POST | `/api/tokens` | `{department_id, visitor_name, phone?}` |
| GET | `/api/tokens/{id}` | - |
| POST | `/api/tokens/{id}/cancel` | - |

Staff (header `Authorization: Bearer <token>`)
| Method | Path | Body |
|---|---|---|
| POST | `/api/auth/login` | `{username, password}` |
| GET | `/api/admin/dashboard` | - |
| GET | `/api/admin/queue?department_id=` | - |
| POST | `/api/admin/departments/{id}/call-next` | - |
| POST | `/api/admin/departments/{id}/pause` | `{paused: true|false}` |
| POST | `/api/admin/tokens/{id}/complete` | - |
| POST | `/api/admin/tokens/{id}/no-show` | - |
| POST | `/api/admin/tokens/{id}/transfer` | `{department_id}` |
| POST | `/api/admin/tokens/{id}/priority` | `{priority: true|false}` |

Errors are `{"error": "message"}` with 400/401/403/404/409.

## 5. Database
Full DDL: [`backend/schema.sql`](backend/schema.sql) - tables `departments`, `staff`, `tokens`, `token_events` (audit log)
plus indexes. It is idempotent and applied automatically at startup.

## 6. Testing
```bash
docker compose up -d
bash scripts/api_smoke_test.sh     # priority, call-next guard, no-show x2, cancel, pause, transfer, RBAC, dashboard
cd frontend && flutter analyze
```

## 7. Suggested demo (for the screenshots / video)
1. Open the app twice (two browser tabs): one as visitor, one logged in as `admin`.
2. Visitor tab: take tokens in IT Support for 3 different names -> show `IT-001..003`, positions and ETA.
3. Staff tab: **Call next** -> visitor 1 sees "It's your turn!", the others' positions drop.
4. Star `IT-003` -> it jumps ahead of `IT-002` but the token being served is untouched.
5. **No show** on the serving token -> goes to the end; do it again -> cancelled automatically.
6. **Pause** HR -> visitor tab shows "Paused" and the button is disabled. **Resume**.
7. **Transfer** a token to Accounts. Show the dashboard counters.

## 8. Push to GitHub
```bash
git init && git add . && git commit -m "ServeNext: Flutter + Go + PostgreSQL"
git branch -M main
git remote add origin https://github.com/<you>/servenext.git && git push -u origin main
```
