# Credit Plus AI Monitoring – Development Log

This file documents what we build and why, so you can refer back anytime.

---

## Project goal

Build an **AI-driven monitor** for batch and report jobs:

1. **Monitor** `BatchLog` and `ReportLog` tables in Oracle.
2. **Detect** when a job is long-running (exceeded expected time) or failed.
3. **Analyze** using AWS Bedrock: feed anomaly + AWR (diagnostic) + code snippets → get root cause and recommendations.
4. **Alert** twice: (1) immediate when anomaly is found, (2) after analysis with AWR + root cause + fix.

We use **dummy data** and **simulated AWR** on a **personal laptop** with **AWS free tier**.

---

## Phase 1: Environment and project setup ✅

**What we did:**

- Created folder structure: `agent/`, `db_scripts/`, `awr_simulated/`, `config/`, `alerts/`.
- Added `config/aws_credentials.env` (template for AWS keys), `config/paths.json`, `.gitignore`, `requirements.txt`.
- Created `agent/__init__.py` so `agent` is a Python package.
- Installed **Java 17** (OpenJDK via Homebrew) for SQLcl.
- Downloaded and extracted **Oracle SQLcl 25.4.2** into `sqlcl/`; added `run_sqlcl.sh` and `SETUP_SQLCL.md`.

**Prerequisites you did manually:** AWS account, Bedrock model access, IAM user, Docker Desktop, Python venv (`python3 -m venv venv` and `pip install -r requirements.txt`).

---

## Phase 2: Oracle database and tables (dummy data) ✅

**Goal:** Run Oracle in Docker, create `BatchLog` and `ReportLog`, insert dummy rows (normal, long-running, failed) so our monitor has something to detect.

**Steps (with explanations):**

### Step 2.1 – Start Oracle Database in Docker

We run Oracle Database 23c Free in a **Docker container** so we don’t install Oracle on the laptop.

- **Image:** `gvenzl/oracle-free:23.26.0-slim-faststart` (official free Oracle 23c, slim image).
- **Container name:** `oracledb` (so we can reference it easily).
- **Port:** `1521` (Oracle listener) mapped to host so we connect to `localhost:1521`.
- **App user:** We create user `creditplus` with password `CreditPlus123`; our Python app and SQLcl use this (no need for DBA account in the app).
- **Service:** The pluggable database is usually `freepdb1`; connection string: `localhost:1521/freepdb1`.

### Step 2.2 – Wait until the database is ready

After starting the container, Oracle takes a few minutes to initialize. We wait until the logs show `DATABASE IS READY TO USE!` before running any SQL.

### Step 2.3 – Connect with SQLcl and save connection

We use SQLcl to run SQL. We connect as `creditplus` and **save** the connection (name: `creditplus_local`) so we can reuse it with `conn creditplus_local` without typing the full string each time.

### Step 2.4 – Create the BatchLog table

**Why this table:** Our “batch jobs” (e.g. daily settlement, sync) are logged here. The monitor will look for rows where `status = 'RUNNING'` and elapsed time &gt; `expected_duration_mins`, or `status = 'FAILED'`.

**Columns:**

| Column | Type | Purpose |
|--------|------|--------|
| `id` | NUMBER (identity) | Auto-increment primary key. |
| `batch_name` | VARCHAR2(128) | Name of the batch (e.g. DAILY_SETTLEMENT). |
| `status` | VARCHAR2(32) | RUNNING, COMPLETED, or FAILED. |
| `start_ts` | TIMESTAMP | When the batch started. |
| `end_ts` | TIMESTAMP | When it ended (NULL if still RUNNING). |
| `expected_duration_mins` | NUMBER | Expected runtime in minutes; we use this to detect “long-running”. |
| `error_message` | VARCHAR2(4000) | Optional; for FAILED jobs we can store the error. |
| `created_at` | TIMESTAMP | Row insert time (default SYSTIMESTAMP). |

### Step 2.5 – Create the ReportLog table

Same idea as BatchLog but for **report jobs** (e.g. merchant statement, regulatory export). Same column logic; the name column is `report_name` instead of `batch_name`.

### Step 2.6–2.7 – Insert “normal” (completed) rows

We insert a few **COMPLETED** batches and reports with `start_ts` and `end_ts` within the expected duration. These represent healthy jobs; the monitor will **not** flag them.

### Step 2.8 – Insert one “long-running” batch

We insert one row: `RECONCILIATION_BATCH`, status **RUNNING**, started 25 minutes ago, expected duration **10** minutes. So “elapsed (25) &gt; expected (10)” → our monitor will treat this as an **anomaly** (long-running).

### Step 2.9 – Insert one “failed” report

We insert one row: `REGULATORY_EXPORT`, status **FAILED**, with an error message (e.g. ORA-01652). The monitor will flag this as an **anomaly** (failed).

### Step 2.10 – Verify data

We run `SELECT` on both tables to confirm: we see the completed rows plus the one long-running batch and one failed report. Then Phase 2 is complete.

---

## Phase 2 – What we actually ran

1. **Docker:** `docker run -d --name oracledb -p 1521:1521 ... gvenzl/oracle-free:23.26.0-slim-faststart`  
   - Started Oracle 23c Free in container `oracledb`; app user `creditplus`/`CreditPlus123`; PDB `freepdb1`.

2. **Wait:** Checked `docker logs oracledb` until we saw `DATABASE IS READY TO USE!`.

3. **SQL script:** All DDL and DML were run from one file: `scripts/phase2_setup.sql`, via:  
   `./run_sqlcl.sh -S creditplus/CreditPlus123@localhost:1521/freepdb1 @scripts/phase2_setup.sql`

4. **Result:**  
   - **BatchLog:** 4 rows (3 COMPLETED, 1 RUNNING – RECONCILIATION_BATCH).  
   - **ReportLog:** 3 rows (2 COMPLETED, 1 FAILED – REGULATORY_EXPORT).

**Reconnect to DB anytime (from project root):**
```bash
./run_sqlcl.sh creditplus/CreditPlus123@localhost:1521/freepdb1
```
Or save the connection in SQLcl: `conn -save creditplus_local -savepwd creditplus/CreditPlus123@localhost:1521/freepdb1`, then `conn creditplus_local`.

**If the container was stopped:** `docker start oracledb` then wait ~30 seconds before connecting.

---

## Phase 3: Simulated AWR and “code repository” ✅

**Goal:** Give the AI agent something to “analyze”: one simulated AWR report and a few sample SQL/PL-SQL files that match our dummy anomalies. The agent will read these in Phase 5 and use them as context for root cause and recommendations.

**What we did:**

1. **awr_simulated/awr_sample.txt**  
   A text file that looks like an AWR snapshot: Load Profile, Top 5 Wait Events, Top SQL by elapsed time (with one sample SQL showing a full scan), and a few parameters. The agent gets this as “diagnostic” context so it can suggest things like “reduce full scan”, “check indexes”, “temp usage”.

2. **db_scripts/batch_reconciliation.sql**  
   Sample PL/SQL for a long-running batch: full scan on `transactions` with `created_at` filter, and an insert into `reconciliation_summary`. Matches the BatchLog anomaly **RECONCILIATION_BATCH** (long-running). The agent can link “this batch is slow” to “this code does full scan / no index”.

3. **db_scripts/report_regulatory_export.sql**  
   Sample SQL for a report that uses a global temporary table and a large insert from `transactions` (12 months). Matches the ReportLog anomaly **REGULATORY_EXPORT** (FAILED with ORA-01652). The agent can link “this report failed” to “temp segment / large result set”.

4. **config/paths.json**  
   Already had the paths we need: `awr_sample_file`, `code_repo_dir`, `alerts_dir`. Phase 5 will read from these.

**Why simulated:**  
On personal laptop we may not have real AWR or real package source. So we use a fixed sample AWR and two sample scripts. On office/dev you can switch to real AWR (or V$SESSION/V$SQL output) and real code repo (or batch_name → package lookup).

**Phase 3 checklist:**  
- `awr_simulated/awr_sample.txt` exists  
- `db_scripts/batch_reconciliation.sql` and `db_scripts/report_regulatory_export.sql` exist  
- `config/paths.json` has the right paths (already set in Phase 1)

---

## Phase 4: Monitor process (anomaly detection) ✅

**Goal:** A Python script that connects to Oracle, polls `BatchLog` and `ReportLog`, and detects “long-running” and “failed” rows. No Bedrock or alerts yet; just detection and print to console.

**What we did:**

1. **agent/db.py**  
   - `load_config()` – reads `config/paths.json` (for use in later phases).  
   - `get_connection()` – connects to Oracle as `creditplus`/`CreditPlus123` at `localhost:1521/freepdb1`.  
   - `fetch_long_running_batches(cur)` – rows from BatchLog where `status = 'RUNNING'`, `end_ts IS NULL`, and elapsed time &gt; `expected_duration_mins`.  
   - `fetch_failed_batches(cur)` – rows from BatchLog where `status = 'FAILED'`.  
   - `fetch_long_running_reports(cur)` – same logic for ReportLog (long-running).  
   - `fetch_failed_reports(cur)` – same for ReportLog (failed).  

2. **agent/monitor.py**  
   - Adds project root to `sys.path` so `agent.db` can be imported when run as `python -m agent.monitor`.  
   - `run_once()` – opens connection, runs all four fetch functions, builds a list of anomaly dicts (each with `source`, `type`, `id`, `name`, `status`, timestamps, `expected_mins`, and for failed: `error_message`).  
   - `main()` – loop every 30 seconds: call `run_once()`, if any anomalies print `[ANOMALY]` with the dict, else print a dot. Catches exceptions and continues.  

**How to run (from project root):**

```bash
# Ensure venv exists and has oracledb (Phase 1 step)
python3 -m venv venv
source venv/bin/activate   # Windows: venv\Scripts\activate
pip install -r requirements.txt

# Ensure Oracle container is running
docker start oracledb   # if needed, wait ~30 sec

# Run monitor (Ctrl+C to stop)
python -m agent.monitor
```

You should see one long-running batch (**RECONCILIATION_BATCH**) and one failed report (**REGULATORY_EXPORT**) printed. Each poll after that will show the same until those rows are updated or removed.

**Phase 4 checklist:**  
- `agent/db.py` and `agent/monitor.py` exist and run without import errors.  
- With Oracle up and venv with `oracledb` installed, `python -m agent.monitor` prints the two anomalies.

---

## Phase 5: Bedrock agent (root cause analysis) ✅

**Goal:** When an anomaly is found, build a prompt with anomaly + AWR + code snippets, call AWS Bedrock (Mumbai), and print root cause + recommendations. No alerting yet; processed anomalies are tracked so we don’t call Bedrock twice.

**What we did:**

1. **config/aws_credentials.env** – Set with your access key, secret key, and **AWS_DEFAULT_REGION=ap-south-1** (Mumbai). This file is in `.gitignore`; only the agent reads it locally.

2. **agent/aws_env.py** – Loads `config/aws_credentials.env` into `os.environ` so boto3 can use the credentials.

3. **agent/bedrock_agent.py** – `read_file()` reads AWR and db_scripts; `build_user_message()` builds the prompt; `invoke_bedrock()` calls Bedrock (Claude 3 Haiku) in the region from env; `run_rca(anomaly)` runs the full flow and returns the model text.

4. **agent/processed.py** – In-memory set of (source, id, type); `is_processed()` / `mark_processed()` so each anomaly triggers RCA only once.

5. **agent/monitor.py** – For each new anomaly (not processed): print anomaly, call `run_rca(a)`, print `[RCA]` and the text, then `mark_processed(a)`. On exception, print `[RCA ERROR]`.

**AWS – kya kya safe hai:**  
- Sirf **Bedrock InvokeModel** use hota hai (model ko prompt bhejna, response lena).  
- Koi resource create/delete nahi, koi billing spike wala heavy use nahi.  
- Account lock se bachne ke liye: Bedrock console mein Mumbai (ap-south-1) pe jaa kar **Model access** → Claude 3 Haiku (or jo model use ho) **Enable** karna zaroori hai; enable ke baad hi invoke chalega.

**Phase 5 checklist:**  
- `config/aws_credentials.env` has correct keys and `AWS_DEFAULT_REGION=ap-south-1`.  
- In AWS Console → Bedrock (Mumbai) → Model access → enable at least one Claude model.  
- `python -m agent.monitor` runs, prints anomalies and then `[RCA]` with root cause and recommendations for each (once per anomaly).

---

## Phase 6: Alerting (two-stage) ✅

**Goal:** Two-stage alerting:  
1. **Alert 1 (immediate):** As soon as an anomaly is detected (before RCA), send an alert with anomaly details.  
2. **Alert 2 (after RCA):** After Bedrock returns root cause + recommendations, send a second alert with AWR snippet + RCA text.

Alerts go to **two channels**:
- **AWS SNS** (email) – if `sns_topic_arn` is configured in `config/paths.json`.
- **Local file** – always written to `alerts/` folder (immediate_*.txt and rca_*.txt).

**What we did:**

1. **agent/alerting.py** – Two main functions:
   - `send_immediate_alert(anomaly)` – builds subject like `[CreditPlus] Anomaly: long_running - RECONCILIATION_BATCH (id=4)`, body is the anomaly as JSON. Calls `_publish()` (SNS) + `_write_local()` (file).
   - `send_rca_alert(anomaly, awr_snippet, rca_text)` – subject like `[CreditPlus] RCA: RECONCILIATION_BATCH (id=4)`, body has anomaly + AWR snippet + root cause + recommendations. Same two channels.
   - `_publish()` – reads `sns_topic_arn` from `config/paths.json`; if empty, skips SNS and prints "(SNS not configured)". If set, publishes via boto3 SNS client.
   - `_write_local()` – writes alert to `alerts/<kind>_<timestamp>.txt`.

2. **agent/monitor.py** – Updated:
   - Imports `send_immediate_alert`, `send_rca_alert`, `read_file`.
   - On new anomaly: `send_immediate_alert(a)` immediately (line 93).
   - After `run_rca(a)` succeeds: read AWR snippet (first 2000 chars), then `send_rca_alert(a, awr_snippet, rca_text)` (lines 97–98).
   - Then `mark_processed(a)`.

**SNS setup (optional, for email alerts):**
1. AWS Console → SNS (Mumbai) → Create topic `creditplus-anomaly-alerts` (Standard).
2. Create subscription: Protocol Email, endpoint your email, confirm via inbox link.
3. Note the Topic ARN and put it in `config/paths.json` → `sns_topic_arn`.
4. IAM user needs `sns:Publish` permission (or `AmazonSNSFullAccess`).

**Without SNS:** Alerts still work – they are saved as local files in `alerts/`. You can demo with just local files.

**Phase 6 checklist:**
- `agent/alerting.py` exists with `send_immediate_alert` and `send_rca_alert`.
- `agent/monitor.py` calls both alert functions.
- `alerts/` folder gets `.txt` files on each anomaly.
- Optional: SNS topic ARN in `config/paths.json` for email alerts.

---

*(Phase 7 / demo prep will be documented here as we do them.)*
