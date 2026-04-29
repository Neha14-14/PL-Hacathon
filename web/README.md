# Credit Plus Monitor Dashboard

Two-page FastAPI UI: **Dashboard** (monitoring, tables, RCA, alerts) and **Run job** (run batch/report from dropdown, see last run status).

## Run

From **project root** (so Oracle config and `agent` package resolve):

```bash
source venv/bin/activate
pip install -r requirements.txt   # if not already
uvicorn web.main:app --reload --host 0.0.0.0 --port 8000
```

- **http://localhost:8000** — Dashboard: Start/Stop monitoring, BatchLog/ReportLog tables (tabs), RCA (BatchLog/ReportLog tabs), Alerts (BatchLog/ReportLog tabs). Status colors: green completed, red failed, amber running.
- **http://localhost:8000/run** — Run job: dropdown (Batches + Reports), Run button, Last run card (ID, name, start time, end time / Running…). Entries appear in BatchLog or ReportLog on the Dashboard.

## API (Phase E)

- `GET /api/job-options` — list batches and reports for the dropdown.
- `POST /api/run-batch` — body `{"name": "RECONCILIATION_BATCH"}` → returns `{ batch_id, name, type }`.
- `POST /api/run-report` — body `{"name": "REGULATORY_EXPORT"}` → returns `{ report_id, name, type }`.
- `GET /api/job-status?type=batch&id=26` — returns `{ id, batch_name, status, start_ts, end_ts }` (or report_name for type=report).

CLI monitor (`python -m agent.monitor`) is unchanged and still works without the dashboard.
