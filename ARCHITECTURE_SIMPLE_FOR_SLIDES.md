# Resilient Credit+ Guardian — Architecture for Hackathon Slides

Use this for a **clear but informative** diagram: not overwhelming, not too vague.

---

## Balanced version (middle ground) — recommended for slides

**Goal:** One diagram that tells the story and shows enough detail (tech + flow) for judges to understand what you built.

### Components (6–7 boxes, one line each)

| Component | What to show |
|-----------|----------------|
| **Oracle Database** | Job logs (BatchLog, ReportLog), PL/SQL batches & reports, live SQL diagnostics (top queries, plans) for the time window when something went wrong. |
| **Python backend (agent)** | Monitor loop (polls DB every 5s), detects long-running or failed jobs; fetches live diagnostics + PL/SQL code from DB; calls Bedrock; sends alerts; keeps in-memory state for the UI. |
| **FastAPI web server** | REST API for dashboard; serves Dashboard and Run Job pages; starts/stops monitor thread; run batch/report, mark as fail, get job status and logs. |
| **Web dashboard (browser)** | Dashboard: monitoring on/off, Batch Log & Report Log tables, Alerts and RCA grouped by job. Run Job: start batch/report, mark as fail, last run status. |
| **AWS Bedrock (Claude)** | Gets: anomaly (job id, name, timings, error) + live diagnostic (top SQL, execution plans, wait events) + relevant PL/SQL code. Returns: ROOT_CAUSE, RECOMMENDATIONS, CODE_FIX. |
| **AWS SNS** | Two alerts per incident: (1) immediate — “anomaly detected”; (2) after RCA — diagnostic snippet + root cause + recommendations. Delivers to email (and optionally SMS/Slack). |
| **Config / local** (optional) | paths.json (SNS topic, alerts dir), AWS credentials; fallback AWR file if live diagnostics fail; local copy of alerts. |

### Flow (what goes where)

- **Dashboard ↔ FastAPI:** Start/stop monitoring, run batch/report, mark fail, refresh; FastAPI returns job lists, status, alerts, RCA.
- **FastAPI / Backend → Oracle:** Read BatchLog & ReportLog; run batches/reports via PL/SQL; get live diagnostics (top SQL, plans, waits) for anomaly time window; get PL/SQL source (ALL_SOURCE) for RCA.
- **Backend → Bedrock:** Send anomaly + diagnostic text + code snippets → receive RCA text.
- **Backend → SNS:** Publish immediate alert; after RCA, publish second alert with diagnostic + RCA.
- **Backend → State:** In-memory alert history and RCA history for dashboard (no extra DB).

### Balanced prompt for diagram AI (copy-paste this)

```
Draw an architecture diagram for a hackathon slide. Clear picture with necessary detail.

Components (label each with the short description below):
1. Oracle Database — Job logs (BatchLog, ReportLog), PL/SQL batches & reports, live SQL diagnostics (top queries, plans) for anomaly time window.
2. Python backend — Monitor (polls DB every 5s), detects long-running/failed jobs; fetches live diagnostics + PL/SQL code; calls Bedrock for RCA; sends alerts; in-memory state for UI.
3. FastAPI — REST API; serves Dashboard and Run Job pages; start/stop monitor; run batch/report, mark fail, get logs and status.
4. Web dashboard — Batch/Report log tables, alerts and RCA by job, start/stop monitoring, run jobs, mark as fail.
5. AWS Bedrock (Claude) — Input: anomaly + live diagnostic (top SQL, plans) + PL/SQL code. Output: root cause, recommendations, code fix.
6. AWS SNS — Two emails per incident: immediate alert, then RCA alert (diagnostic + analysis).

Connections (draw arrows and label briefly):
- Dashboard ↔ FastAPI (control, job lists, alerts, RCA)
- FastAPI / Backend → Oracle (read logs, run jobs, get live diagnostics and code)
- Backend → Bedrock (send context → get RCA)
- Backend → SNS (immediate alert, then RCA alert)
- Backend uses in-memory state for dashboard data

Keep it readable: 6 boxes, 5–6 arrows with short labels. Include the tech names (Oracle, Python, FastAPI, Bedrock/Claude, SNS) so the stack is clear.
```

---

## Simple version (minimal)

Use when you need the absolute minimum on one slide.

### Simple components (5–6 boxes only)

1. **Database** — Stores batch and report runs (job logs, status, timings). Runs business logic (batches/reports).
2. **Monitoring & orchestration (backend)** — Checks the database on a schedule. When a job is too slow or failed, it gathers context and triggers analysis and alerts.
3. **Web dashboard** — Operator sees job logs, starts/stops monitoring, runs jobs, marks jobs as failed. Gets alerts and root-cause analysis on the same screen.
4. **AI (Claude on AWS Bedrock)** — Receives the problem summary + database diagnostics + relevant code. Returns root cause, recommendations, and a suggested code fix.
5. **Notifications (AWS SNS)** — Sends two emails per incident: one as soon as we detect the problem, one after AI returns the analysis.

Optional 6th box: **Config** (paths, AWS settings) — only if you want to show “where settings live.”

### Simple flow (3–4 arrows)

- **Dashboard** → **Backend**: Start/stop monitoring, run jobs, mark as fail, refresh data.
- **Backend** → **Database**: Read job logs, run batches/reports, get live diagnostics when something goes wrong.
- **Backend** → **AI**: Send anomaly + diagnostics + code → get root cause and fix.
- **Backend** → **Notifications**: Send “problem detected” and “RCA ready” alerts (e.g. email).

### Simple prompt for diagram AI

**Copy-paste this to your diagram AI:**

```
Draw a simple architecture diagram for a hackathon slide.

Components (use 5–6 boxes only):
1. Database — stores batch/report job logs and runs business logic.
2. Backend (monitoring & orchestration) — polls database, detects slow or failed jobs, gathers diagnostics and code, calls AI, sends alerts.
3. Web dashboard — operator starts/stops monitoring, runs jobs, sees logs and alerts.
4. AI (Claude on AWS Bedrock) — receives problem + diagnostics + code; returns root cause, recommendations, and code fix.
5. Notifications (AWS SNS) — sends two emails per incident: immediate alert and RCA alert.

Connections (simple arrows with short labels):
- Dashboard → Backend (control and data)
- Backend → Database (read logs, run jobs, get diagnostics)
- Backend → AI (get root cause analysis)
- Backend → Notifications (send alerts)

Keep it minimal and readable. No long technical names. Suitable for a 1-minute explanation.
```

---

## Even shorter one-liner (if the AI needs a single sentence)

```
Architecture: Web Dashboard talks to a Backend that polls a Database for job status; when a job is slow or failed the Backend sends context to AI (Claude on AWS Bedrock) for root cause analysis and then sends two alerts via AWS SNS (immediate + after RCA). Draw 5 boxes: Database, Backend, Dashboard, AI, SNS; show arrows between them with simple labels.
```

---

## Which to use

| Use case | File / section |
|----------|----------------|
| **Slide: clear picture + necessary info** | **Balanced version** (top of this file) + “Balanced prompt for diagram AI” |
| **Slide: very minimal** | Simple version + Simple prompt |
| **Full technical diagram** | ARCHITECTURE_FOR_DIAGRAM.md |
