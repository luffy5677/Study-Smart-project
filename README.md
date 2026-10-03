# Study Smart — local stack

AI-assisted personalized scheduling: **Spring Boot** API, optional **PostgreSQL** or **H2** for quick local runs, **FastAPI + Ollama** microservice, **React (JSX) + Vite** SPA. Everything on your machine uses plain **HTTP** (`http://localhost:...`).

## Easiest: run on Windows (no Docker)

### One command — install everything and start the app

From the project root (first run downloads JDK/Node/Python if missing via **winget**, Maven, npm, Python `.venv`, frees ports **8080/5173/8001**, then starts the stack):

```powershell
.\scripts\setup-and-run.ps1
```

Or double-click **`setup-and-run.cmd`**.

Options: `-SkipSoftwareInstall` (tools already installed), `-SkipBuild` (reuse existing JAR), `-NoBrowser`.

### Manual start (lighter)

1. Install **JDK 17** and **Node.js**.
2. From the project root, **first time only** (downloads Maven into `backend\tools`, then builds the API JAR):

```powershell
.\scripts\start-local.ps1 -Build
```

3. Next times (or if you already have `backend\target\studysmart-backend-*.jar`):

```powershell
.\scripts\start-local.ps1
```

Or double-click **`start-local.cmd`** (add `-Build` once from a terminal: `.\start-local.cmd -Build`).

This starts:

- **API:** http://localhost:8080 (`local` profile → in-memory **H2**, Flyway off; **no** Postgres required)
- **Web app:** http://localhost:5173 — Vite proxies `/api` to the API

Swagger: http://localhost:8080/swagger-ui.html

### If Edge says “can't reach localhost:5173” (ERR_CONNECTION_REFUSED)

The **Vite dev server is not running yet** (or the window that runs it closed). Do this:

1. Open **`frontend\start-dev.bat`** and **leave that CMD window open**.
2. Wait until you see **`Local: http://127.0.0.1:5173`** (or `localhost:5173`), then reload the browser.

First run may run `npm install` for several minutes.

If **`npm install`** errors with **`UNABLE_TO_VERIFY_LEAF_SIGNATURE`**, use the included [`frontend/.npmrc`](frontend/.npmrc) (`strict-ssl=false`) for local dev behind TLS-inspecting proxies; remove it once your machine trusts the registry.

## URLs (pinned)

| Surface | URL |
|--------|-----|
| React (Vite dev) | http://localhost:5173 |
| Spring Boot API + Swagger UI | http://localhost:8080/swagger-ui.html |
| AI service (optional) | http://localhost:8001 |
| Postgres (if you use Docker / default profile) | localhost `5432` |
| Ollama (Compose profile `ollama`) | http://localhost:11434 |

## Docker Compose (full stack with Postgres)

1. Copy [`.env.example`](.env.example) to `.env`.
2. Run: `docker compose up --build`

## Backend with real PostgreSQL (optional)

Default JDBC in `application.yml` uses `sslmode=disable` for local Postgres without TLS. Set `SPRING_DATASOURCE_*` or use Compose.

```powershell
cd backend
.\mvnw.cmd spring-boot:run
```

## AI service — Python `.venv` (optional)

```powershell
cd ai-service
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
uvicorn app.main:app --reload --port 8001
```

Turn AI back on for the Java app with env `STUDYSMART_AI_ENABLED=true` (default in `application-local.yml` is **off** so the stack runs without Python).

## Frontend only

```bash
cd frontend
npm install
npm run dev
```

## Tests

- **Backend:** `cd backend && .\mvnw.cmd test`
- **AI:** `cd ai-service && pip install -r requirements-dev.txt && pytest`
- **Frontend:** `cd frontend && npm test`

## Architecture

Browser → **Java API** (auth, CRUD, deterministic schedule) → optional **FastAPI** → **Ollama** for session tips; baseline schedule still works if AI is down.

## Admin vs student roles

| Role | Login | Capabilities |
|------|-------|----------------|
| **Admin** | `admin@studysmart.com` / `Admin@12345` (auto-created on startup) | Create courses & modules, publish courses, view live student progress |
| **Student** | Register at `/register` | Browse catalog, enroll, complete modules, track progress % |

Admin UI: **Manage courses** (`/admin/courses`), **Live student progress** (`/admin/progress` — real-time SSE updates).

Student UI: **Courses** (`/courses`) — enroll, mark modules complete, log study minutes; progress refreshes every few seconds.
