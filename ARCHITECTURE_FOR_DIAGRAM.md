# Resilient Credit+ Guardian — Architecture for Diagram Generation

Use this as the prompt for your AI agent that converts text to diagrams. It describes components, technologies, and connections.

---

## 1. COMPONENTS (boxes / nodes)

- **Oracle Database** — Runs in Docker (gvenzl/oracle-free). Contains: BatchLog table, ReportLog table, PL/SQL packages (PKG_JOB_RUNNER, PKG_RECONCILIATION, PKG_FRAUD_CHECK, PKG_MERCHANT_REPORT, PKG_REGULATORY_EXPORT, PKG_SETTLEMENT, PKG_EOD_BALANCE, PKG_TXN_SYNC, PKG_DAILY_SUMMARY), sequences for job IDs (BATCH_JOB_ID_SEQ, REPORT_JOB_ID_SEQ), and business tables (e.g. TRANSACTIONS, RECONCILIATION_SUMMARY, FRAUD_ALERTS). Also exposes Oracle data dictionary views: V$SQL, V$SQLTEXT, V$SQL_PLAN (for live diagnostics).

- **Python Application (Agent)** — Backend process. Contains: database access layer, monitor loop, RCA orchestrator, alerting, job runner, in-memory state, and diagnostics/code-crawl modules. Technology: Python 3, oracledb driver, boto3 (AWS SDK), threading.

- **FastAPI Web Server** — Serves the dashboard and REST API. Technology: FastAPI, Uvicorn. Serves static HTML/JS (Dashboard and Run Job pages). Exposes REST endpoints for dashboard data, monitor start/stop, run batch/report, fail job, job status.

- **Dashboard UI** — Browser-based. Two pages: Dashboard (monitoring status, Batch Log table, Report Log table, Alerts and RCA grouped by Job ID) and Run Job (start batch/report, mark as fail, view last run status). Technology: HTML, CSS, JavaScript; fetches data from FastAPI REST API.

- **AWS Bedrock** — Cloud LLM service. Model: Claude 3 Haiku (anthropic.claude-3-haiku). Used for Root Cause Analysis: receives anomaly JSON, diagnostic text (live from V$SQL or fallback), and PL/SQL code snippets; returns structured ROOT_CAUSE, RECOMMENDATIONS, and CODE_FIX.

- **AWS SNS** — Simple Notification Service. One SNS Topic (e.g. creditplus-anamoly-alerts). Receives two types of messages: (1) Immediate alert when an anomaly is detected, (2) RCA alert after Bedrock returns analysis (includes AWR/diagnostic snippet and RCA text). Delivers to email (and optionally SMS/Slack via subscriptions).

- **Config / Local Files** — config/paths.json (sns_topic_arn, alerts_dir, awr_sample_file, code_repo_dir); config/aws_credentials.env for AWS keys; optional fallback file awr_simulated/awr_sample.txt when live V$SQL returns no data; local alerts/ folder where alert emails are also saved as .txt files.

---

## 2. TECHNOLOGIES BY COMPONENT

| Component           | Technologies |
|--------------------|--------------|
| Oracle Database    | Oracle Database (Free 23c), Docker, PL/SQL, SQL, V$ views (V$SQL, V$SQLTEXT, V$SQL_PLAN) |
| Python Agent       | Python 3, oracledb, boto3, threading |
| Web Server         | FastAPI, Uvicorn |
| Dashboard UI       | HTML, CSS, JavaScript, fetch API |
| AI / RCA           | AWS Bedrock, Claude 3 Haiku |
| Notifications      | AWS SNS, (optional) SES for email |
| Config / Storage   | JSON (paths.json), .env, local filesystem (alerts/, awr_simulated/) |

---

## 3. CONNECTIONS (who talks to whom; draw arrows with labels)

- **Dashboard UI → FastAPI** — HTTP GET/POST. GET: /api/batchlog, /api/reportlog, /api/status, /api/job-options, /api/job-status. POST: /api/start-monitor, /api/stop-monitor, /api/run-batch, /api/run-report, /api/fail-job.

- **FastAPI → Oracle Database** — TCP (oracledb, port 1521, service freepdb1). Queries: BatchLog, ReportLog, user_tab_columns; calls PL/SQL: PKG_JOB_RUNNER (START_BATCH, EXEC_AND_FINISH_BATCH, START_REPORT, EXEC_AND_FINISH_REPORT, REQUEST_CANCEL_BATCH, REQUEST_CANCEL_REPORT); sequences for job_id. Used by: db module, job_runner, monitor (via db), diagnostics, code_crawl, and FastAPI log/status/run/fail endpoints.

- **Monitor (inside Python Agent) → Oracle Database** — Same as above. Monitor loop runs in a background thread started by FastAPI. Every 5 seconds it runs: fetch_long_running_batches, fetch_failed_batches, fetch_long_running_reports, fetch_failed_reports. Builds anomaly list from BatchLog and ReportLog.

- **Monitor → Diagnostics (same process)** — When an anomaly is found, monitor calls run_rca(anomaly). run_rca calls fetch_diagnostic_report(anomaly), which uses the same Oracle connection to query V$SQL, V$SQLTEXT, V$SQL_PLAN in the anomaly time window (start_ts to end_ts or SYSDATE). Result: live diagnostic report (top SQL by elapsed time, SQL text, execution plans).

- **Diagnostics → Oracle Database** — oracledb connection. Queries: V$SQL (TOP SQL by elapsed in time window), V$SQLTEXT (SQL text by sql_id), V$SQL_PLAN (execution plan by sql_id). Uses TO_DATE with anomaly start_ts/end_ts for the time window.

- **Code Crawl → Oracle Database** — oracledb. Uses SQL_IDs from diagnostics (or fallback by batch/report name) to search ALL_SOURCE for PL/SQL objects containing that SQL; then fetches full source of those objects. Result: PL/SQL code snippets for the RCA prompt.

- **Bedrock Agent (same process) → AWS Bedrock** — HTTPS (boto3 bedrock-runtime). Sends one user message (anomaly JSON + diagnostic text + code snippets) and system prompt; receives one response (RCA text: ROOT_CAUSE, RECOMMENDATIONS, CODE_FIX). Region: ap-south-1 (configurable via AWS_DEFAULT_REGION).

- **Alerting → AWS SNS** — HTTPS (boto3 SNS). Publishes to one SNS Topic (ARN from config/paths.json). Two publish calls per anomaly: (1) immediate alert (subject + body with anomaly JSON), (2) RCA alert (subject + body with anomaly, AWR/diagnostic snippet, and RCA text). Also writes same content to local alerts/ folder as .txt files.

- **Monitor → State (in-memory)** — Same process. Monitor (and alerting) updates: alert_history, rca_history, last_rca, rca_loading, monitoring_active, stop_requested. No network; shared memory.

- **FastAPI → State** — Same process. On startup: clear_session() and clear BatchLog/ReportLog and reset sequences. GET /api/status returns get_status() (rca_loading, last_rca, rca_history, alert_history, monitoring_active). POST /api/start-monitor starts monitor thread; POST /api/stop-monitor sets request_stop() so monitor exits.

- **Job Runner → Oracle Database** — oracledb. START_BATCH / START_REPORT (inserts row, returns job_id); EXEC_AND_FINISH_BATCH / EXEC_AND_FINISH_REPORT (runs the actual PL/SQL package and updates BatchLog/ReportLog); REQUEST_CANCEL_BATCH / REQUEST_CANCEL_REPORT (sets cancel_requested). Run batch/report is asynchronous: one thread inserts and returns job_id, another thread executes the package.

- **Config → Agent / Alerting / Bedrock** — paths.json read by alerting (sns_topic_arn, alerts_dir) and by bedrock_agent (optional awr fallback path). AWS credentials from aws_credentials.env (or environment) for boto3 (Bedrock, SNS).

---

## 4. DATA FLOW (summary for arrows)

1. **User starts monitoring** — Browser clicks Start → FastAPI POST /api/start-monitor → starts Monitor thread. Monitor every 5s: Oracle (BatchLog, ReportLog) → anomalies list.

2. **Anomaly detected** — Monitor gets long_running or failed row from Oracle. Sends immediate alert: Alerting → SNS (and local file) and State (alert_history). Then: Diagnostics → Oracle (V$SQL, V$SQLTEXT, V$SQL_PLAN) for that anomaly’s time window; Code Crawl → Oracle (ALL_SOURCE) for PL/SQL snippets; Bedrock Agent → AWS Bedrock with anomaly + diagnostic + code → RCA text. Then: State (rca_history, last_rca); Alerting → SNS + local file (RCA alert with diagnostic snippet + RCA text).

3. **User runs a batch/report** — Browser selects batch/report → FastAPI POST /api/run-batch or /api/run-report → Job Runner → Oracle (START_BATCH/START_REPORT, then background thread EXEC_AND_FINISH_*). Oracle updates BatchLog/ReportLog; Dashboard polls /api/batchlog, /api/reportlog and /api/status to show tables and alerts/RCA.

4. **User marks job as fail** — Browser clicks Mark as Fail → FastAPI POST /api/fail-job → Job Runner REQUEST_CANCEL_* → Oracle sets cancel_requested; procedure checks flag and exits. Monitor ignores such failures for RCA (no Bedrock, no duplicate alerts).

---

## 5. LAYERS (optional grouping for diagram)

- **Presentation:** Dashboard UI (browser).
- **API / Orchestration:** FastAPI Web Server (REST, static pages, monitor thread launcher).
- **Business Logic / Agent:** Python modules: monitor, job_runner, state, processed (dedup), alerting, bedrock_agent, diagnostics, code_crawl, db.
- **Data:** Oracle Database (BatchLog, ReportLog, PL/SQL packages, V$ views, ALL_SOURCE, sequences).
- **External Services:** AWS Bedrock (Claude), AWS SNS (notifications).
- **Config / Local:** paths.json, awr_simulated/, alerts/, aws_credentials.env.

---

## 6. ONE-LINE PROMPT FOR DIAGRAM AGENT

"Draw an architecture diagram with these components: Oracle Database in Docker (BatchLog, ReportLog, PL/SQL packages, V$SQL views); Python Agent (monitor, diagnostics, code_crawl, bedrock_agent, alerting, job_runner, state); FastAPI Web Server serving Dashboard UI; Dashboard UI in browser; AWS Bedrock (Claude); AWS SNS Topic; Config and local files. Show: Dashboard → FastAPI (REST); FastAPI and Monitor and Job Runner and Diagnostics and Code Crawl → Oracle (SQL/PL/SQL); Bedrock Agent → Bedrock (RCA); Alerting → SNS and local alerts; Monitor and Alerting → State (in-memory); FastAPI starts/stops Monitor and reads State. Label technologies: Oracle, Python/oracledb/boto3, FastAPI/Uvicorn, HTML/JS, AWS Bedrock/Claude, AWS SNS."
