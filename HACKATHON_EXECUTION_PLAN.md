# Credit Plus AI Monitoring – Phased Execution Plan

This document is your step-by-step guide. Each phase lists **every action** in order, including exact statements (CREATE TABLE, INSERT, config snippets, commands). Do phases in order; each phase builds on the previous one.

---

# Phase 1: Environment and Project Setup

**Goal:** Laptop ready with folders, accounts, and tools. No database or code yet.

**Duration (approx.):** 1–2 hours

---

## 1.1 Create project folder structure

On your laptop, create the project root and subfolders.

**Commands (run from your project root, e.g. `~/Desktop/hacathon` or `C:\hacathon`):**

```bash
mkdir -p hacathon
cd hacathon
mkdir -p agent db_scripts awr_simulated config alerts
```

**Resulting structure:**

```
hacathon/
├── agent/           # Python monitor + Bedrock agent
├── db_scripts/      # Sample PL/SQL and SQL (fake “code repo”)
├── awr_simulated/   # Simulated AWR report files
├── config/          # Config and env templates
└── alerts/          # Optional: local alert log files
```

---

## 1.2 AWS account and Bedrock

1. **Create or use an AWS account** (free tier): https://aws.amazon.com  
2. **Enable MFA** on the root user (recommended).  
3. **Open Bedrock console:** AWS Console → search “Bedrock” → open Amazon Bedrock.  
4. **Enable Bedrock in one region** (e.g. `us-east-1`): left menu “Get started” or “Model access”; request access for at least one model (e.g. Claude 3 Haiku or Claude 3.5 Sonnet). Approve if it asks for access.  
5. **Note your region**, e.g. `us-east-1`. You will use it in config later.

---

## 1.3 IAM user for Bedrock (recommended)

1. **IAM → Users → Create user.**  
   - User name: `bedrock-agent`  
   - No console login; access type: **Programmatic access**.  
2. **Attach policy:** `AmazonBedrockFullAccess` (or a custom policy that allows `bedrock:InvokeModel` and `bedrock:InvokeModelWithResponseStream`).  
3. **Create access key** (CLI); download or copy **Access key ID** and **Secret access key**.  
4. **Create a config file** (do not commit this file to git):

**File: `config/aws_credentials.env`** (create this file, add to `.gitignore`):

```
AWS_ACCESS_KEY_ID=AKIAxxxxxxxxxxxxxxxx
AWS_SECRET_ACCESS_KEY=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
AWS_DEFAULT_REGION=us-east-1
```

Replace with your real values. Add `config/aws_credentials.env` to `.gitignore`.

---

## 1.4 Install Docker

1. **Install Docker Desktop:**  
   - macOS: https://docs.docker.com/desktop/install/mac-install/  
   - Windows: https://docs.docker.com/desktop/install/windows-install/  
2. **Start Docker Desktop.**  
3. **Verify:**

```bash
docker --version
docker run hello-world
```

You should see “Hello from Docker!”.

---

## 1.5 Install Java 17+

1. **Check Java:** `java -version`  
2. **If missing or older than 17:**  
   - macOS: `brew install openjdk@17` and follow instructions to link.  
   - Or download from https://adoptium.net/ (Temurin 17).  
3. **Verify:** `java -version` shows 17 or higher.

---

## 1.6 Download and set up Oracle SQLcl

1. **Download SQLcl:** https://www.oracle.com/database/sqldeveloper/technologies/sqlcl/download/  
   - Or direct: https://download.oracle.com/otn_software/java/sqldeveloper/sqlcl-latest.zip  
2. **Unzip** to a folder, e.g. `~/sqlcl` or `C:\sqlcl`.  
3. **Path to executable:**  
   - macOS/Linux: `~/sqlcl/bin/sql`  
   - Windows: `C:\sqlcl\bin\sql.exe`  
4. **Add to PATH (optional)** or note the full path; you will use it for MCP and connections.  
5. **Test:** Run `sql -version` from the `bin` directory.

---

## 1.7 Python environment

1. **Create virtual environment** (from project root `hacathon/`):

```bash
cd hacathon
python3 -m venv venv
```

2. **Activate:**  
   - macOS/Linux: `source venv/bin/activate`  
   - Windows: `venv\Scripts\activate`  

3. **Install packages:**

```bash
pip install boto3 oracledb requests
```

4. **Verify:** `python -c "import boto3, oracledb; print('OK')"`

---

## 1.8 Optional: billing alert

1. In AWS Console: **Billing → Budgets → Create budget.**  
2. Choose **Cost budget**, set amount **$0.01**, add email alert.  
3. This warns you if any charge appears.

---

**Phase 1 checklist:** Folders created, AWS account with Bedrock enabled, IAM user and `config/aws_credentials.env`, Docker and Java and SQLcl and Python venv working.

---

# Phase 2: Oracle database and tables (dummy data)

**Goal:** Oracle DB running in Docker with `BatchLog` and `ReportLog` created and filled with dummy rows (normal, long-running, failed).

**Duration (approx.):** 1–2 hours (including DB first start)

---

## 2.1 Start Oracle Database in Docker

**Command (one line):**

```bash
docker run -d \
  --name oracledb \
  -p 1521:1521 \
  -e ORACLE_RANDOM_PASSWORD=y \
  -e APP_USER=creditplus \
  -e APP_USER_PASSWORD=CreditPlus123 \
  gvenzl/oracle-free:23.26.0-slim-faststart
```

**Windows (PowerShell)** – same in one line or split:

```powershell
docker run -d --name oracledb -p 1521:1521 -e ORACLE_RANDOM_PASSWORD=y -e APP_USER=creditplus -e APP_USER_PASSWORD=CreditPlus123 gvenzl/oracle-free:23.26.0-slim-faststart
```

**Notes:**  
- First run will pull the image (several minutes).  
- `ORACLE_RANDOM_PASSWORD=y` prints the DBA password in logs; we use app user `creditplus` for the app.  
- Connection: `localhost:1521`, service name usually `freepdb1`.

---

## 2.2 Wait until the database is ready

**Command:**

```bash
docker logs -f oracledb
```

**Wait until you see** a line like: `DATABASE IS READY TO USE!`  
Then press `Ctrl+C`. Typical wait: 2–5 minutes.

**Optional – check container:**

```bash
docker ps
```

You should see `oracledb` running.

---

## 2.3 Connect with SQLcl and save connection

1. **Connect** (replace path with your SQLcl `bin`):

```bash
# macOS/Linux example
~/sqlcl/bin/sql creditplus/CreditPlus123@localhost:1521/freepdb1
```

2. **Save the connection** (so you can reuse it):

```sql
conn -save creditplus_local -savepwd creditplus/CreditPlus123@localhost:1521/freepdb1
```

3. **Test:** `conn creditplus_local` then run `SELECT 1 FROM DUAL;` and exit when done.

---

## 2.4 Create the BatchLog table

**Run this in SQLcl** (connected to `creditplus_local` or the same user/pwd/host/service):

```sql
CREATE TABLE BatchLog (
  id                     NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  batch_name             VARCHAR2(128) NOT NULL,
  status                 VARCHAR2(32)  NOT NULL,
  start_ts               TIMESTAMP,
  end_ts                 TIMESTAMP,
  expected_duration_mins NUMBER,
  error_message          VARCHAR2(4000),
  created_at             TIMESTAMP DEFAULT SYSTIMESTAMP
);

COMMENT ON TABLE BatchLog IS 'Log of batch job executions for monitoring';
COMMENT ON COLUMN BatchLog.status IS 'RUNNING, COMPLETED, FAILED';
COMMENT ON COLUMN BatchLog.expected_duration_mins IS 'Expected completion time in minutes';
```

---

## 2.5 Create the ReportLog table

**Run this in SQLcl:**

```sql
CREATE TABLE ReportLog (
  id                     NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  report_name            VARCHAR2(128) NOT NULL,
  status                 VARCHAR2(32)  NOT NULL,
  start_ts               TIMESTAMP,
  end_ts                 TIMESTAMP,
  expected_duration_mins NUMBER,
  error_message          VARCHAR2(4000),
  created_at             TIMESTAMP DEFAULT SYSTIMESTAMP
);

COMMENT ON TABLE ReportLog IS 'Log of report job executions for monitoring';
COMMENT ON COLUMN ReportLog.status IS 'RUNNING, COMPLETED, FAILED';
COMMENT ON COLUMN ReportLog.expected_duration_mins IS 'Expected completion time in minutes';
```

---

## 2.6 Insert dummy “normal” (completed) rows – BatchLog

**Run in SQLcl:**

```sql
INSERT INTO BatchLog (batch_name, status, start_ts, end_ts, expected_duration_mins) VALUES
('DAILY_SETTLEMENT', 'COMPLETED', SYSTIMESTAMP - INTERVAL '2' HOUR, SYSTIMESTAMP - INTERVAL '2' HOUR + INTERVAL '45' MINUTE, 60);
INSERT INTO BatchLog (batch_name, status, start_ts, end_ts, expected_duration_mins) VALUES
('CARD_TXN_SYNC', 'COMPLETED', SYSTIMESTAMP - INTERVAL '1' HOUR, SYSTIMESTAMP - INTERVAL '1' HOUR + INTERVAL '5' MINUTE, 10);
INSERT INTO BatchLog (batch_name, status, start_ts, end_ts, expected_duration_mins) VALUES
('FEE_CALC', 'COMPLETED', SYSTIMESTAMP - INTERVAL '30' MINUTE, SYSTIMESTAMP - INTERVAL '30' MINUTE + INTERVAL '2' MINUTE, 5);
COMMIT;
```

---

## 2.7 Insert dummy “normal” rows – ReportLog

**Run in SQLcl:**

```sql
INSERT INTO ReportLog (report_name, status, start_ts, end_ts, expected_duration_mins) VALUES
('MERCHANT_STATEMENT', 'COMPLETED', SYSTIMESTAMP - INTERVAL '3' HOUR, SYSTIMESTAMP - INTERVAL '3' HOUR + INTERVAL '15' MINUTE, 20);
INSERT INTO ReportLog (report_name, status, start_ts, end_ts, expected_duration_mins) VALUES
('DAILY_REVENUE', 'COMPLETED', SYSTIMESTAMP - INTERVAL '1' HOUR, SYSTIMESTAMP - INTERVAL '1' HOUR + INTERVAL '8' MINUTE, 10);
COMMIT;
```

---

## 2.8 Insert one “long-running” row – BatchLog

This row represents a job that is still RUNNING and has **exceeded** its expected duration (e.g. expected 10 minutes, started 25 minutes ago).

**Run in SQLcl:**

```sql
INSERT INTO BatchLog (batch_name, status, start_ts, end_ts, expected_duration_mins) VALUES
('RECONCILIATION_BATCH', 'RUNNING', SYSTIMESTAMP - INTERVAL '25' MINUTE, NULL, 10);
COMMIT;
```

---

## 2.9 Insert one “failed” row – ReportLog

**Run in SQLcl:**

```sql
INSERT INTO ReportLog (report_name, status, start_ts, end_ts, expected_duration_mins, error_message) VALUES
('REGULATORY_EXPORT', 'FAILED', SYSTIMESTAMP - INTERVAL '15' MINUTE, SYSTIMESTAMP - INTERVAL '14' MINUTE, 5, 'ORA-01652: unable to extend temp segment');
COMMIT;
```

---

## 2.10 Verify data

**Run in SQLcl:**

```sql
SELECT id, batch_name, status, start_ts, expected_duration_mins FROM BatchLog ORDER BY id;
SELECT id, report_name, status, start_ts, expected_duration_mins FROM ReportLog ORDER BY id;
```

You should see completed rows plus one RUNNING batch and one FAILED report.

---

**Phase 2 checklist:** Oracle container running, `BatchLog` and `ReportLog` created, dummy data inserted and verified.

---

# Phase 3: Simulated AWR and “code repository”

**Goal:** One simulated AWR report file and a few sample SQL/PL-SQL files so the AI agent can “analyze” diagnostics and code.

**Duration (approx.):** 30–45 minutes

---

## 3.1 Create simulated AWR report file

**File to create:** `awr_simulated/awr_sample.txt`

**Exact content** (copy-paste):

```text
=============================================
AWR SNAPSHOT SUMMARY (Simulated for Demo)
=============================================
Snapshot ID: 1
Begin time: 23-FEB-25 10:00:00
End time:   23-FEB-25 11:00:00

---------------------------------------------
LOAD PROFILE
---------------------------------------------
DB Time(s):           3,450
DB CPU(s):            2,100
Redo size:           125,000 bytes
Logical reads:       2,500,000
Parses:               45,000
Hard parses:          120

---------------------------------------------
TOP 5 WAIT EVENTS BY TIME
---------------------------------------------
Event                          Waits    Time(s)   Avg(ms)
db file sequential read        85,000   1,200     14.1
CPU time                        -       1,100     -
enq: TX - row lock contention  2,500     450      180.0
log file sync                   1,200     320      266.7
direct path read temp           800      280      350.0

---------------------------------------------
TOP SQL BY ELAPSED TIME (PLAN HASH)
---------------------------------------------
SQL_ID        Elapsed(s)  Executions  Elapsed per Exec
------------- ----------  ----------  ----------------
abc123xyz     1,250       1           1,250.00
def456uvw      890       2             445.00
ghi789rst      340       15             22.67

SQL_ID abc123xyz:
  SELECT /*+ FULL(t) */ SUM(amount), merchant_id
  FROM transactions t
  GROUP BY merchant_id;

---------------------------------------------
PARAMETER (Sample)
---------------------------------------------
optimizer_mode                 = ALL_ROWS
cursor_sharing                  = EXACT
db_file_multiblock_read_count  = 128
```

Save the file under `hacathon/awr_simulated/awr_sample.txt`.

---

## 3.2 Create sample “batch” SQL (code repo)

**File to create:** `db_scripts/batch_reconciliation.sql`

**Exact content:**

```sql
-- batch_reconciliation.sql
-- Simulated long-running batch (full scan, no index)
DECLARE
  v_count NUMBER;
BEGIN
  SELECT COUNT(*)
    INTO v_count
    FROM transactions t
   WHERE t.created_at >= TRUNC(SYSDATE) - 30;
  -- Heavy aggregation without index on created_at
  INSERT INTO reconciliation_summary (batch_date, total_count, updated_at)
  SELECT TRUNC(SYSDATE), COUNT(*), SYSTIMESTAMP
    FROM transactions
   WHERE created_at >= TRUNC(SYSDATE) - 7
   GROUP BY TRUNC(SYSDATE);
  COMMIT;
END;
/
```

---

## 3.3 Create sample “report” SQL (code repo)

**File to create:** `db_scripts/report_regulatory_export.sql`

**Exact content:**

```sql
-- report_regulatory_export.sql
-- Export to temp; may hit ORA-01652 if temp too small
CREATE GLOBAL TEMPORARY TABLE export_work (
  id NUMBER,
  merchant_id VARCHAR2(32),
  txn_date DATE,
  amount NUMBER(18,2)
) ON COMMIT PRESERVE ROWS;

INSERT INTO export_work (id, merchant_id, txn_date, amount)
SELECT ROWNUM, merchant_id, txn_date, amount
  FROM transactions
 WHERE txn_date >= ADD_MONTHS(TRUNC(SYSDATE), -12);
-- Large result set can exhaust temp tablespace
```

---

## 3.4 Create config file for paths

**File to create:** `config/paths.json`

**Exact content** (adjust paths if your project root is different):

```json
{
  "project_root": ".",
  "awr_simulated_dir": "awr_simulated",
  "awr_sample_file": "awr_simulated/awr_sample.txt",
  "code_repo_dir": "db_scripts",
  "alerts_dir": "alerts"
}
```

Use these paths from your agent code to read AWR and code files.

---

**Phase 3 checklist:** `awr_simulated/awr_sample.txt` exists, `db_scripts/batch_reconciliation.sql` and `db_scripts/report_regulatory_export.sql` exist, `config/paths.json` created.

---

# Phase 4: Monitor process (anomaly detection)

**Goal:** A Python script that connects to Oracle, polls `BatchLog` and `ReportLog`, and detects “long-running” and “failed” rows. No Bedrock or alerts yet; just detection and print/log.

**Duration (approx.):** 1–2 hours

---

## 4.0 Make `agent` a Python package

**File to create:** `agent/__init__.py`  
**Content:** Empty file (or a single line: `# agent package`).  
This allows `python -m agent.monitor` to run.

---

## 4.1 DB connection module

**File to create:** `agent/db.py`

**Exact content** (fix path to `config` if needed; e.g. run from `hacathon/` so `config/paths.json` is found):

```python
import oracledb
import os
import json

def load_config():
    base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    with open(os.path.join(base, "config", "paths.json")) as f:
        return json.load(f)

def get_connection():
    return oracledb.connect(
        user="creditplus",
        password="CreditPlus123",
        dsn="localhost:1521/freepdb1",
    )

def fetch_long_running_batches(cursor):
    cursor.execute("""
        SELECT id, batch_name, status, start_ts, expected_duration_mins,
               ROUND((SYSTIMESTAMP - start_ts) * 24 * 60, 2) AS elapsed_mins
        FROM BatchLog
        WHERE status = 'RUNNING'
          AND end_ts IS NULL
          AND expected_duration_mins IS NOT NULL
          AND (SYSTIMESTAMP - start_ts) * 24 * 60 > expected_duration_mins
        ORDER BY start_ts
    """)
    return cursor.fetchall()

def fetch_failed_batches(cursor):
    cursor.execute("""
        SELECT id, batch_name, status, start_ts, end_ts, expected_duration_mins, error_message
        FROM BatchLog
        WHERE status = 'FAILED'
        ORDER BY start_ts DESC
    """)
    return cursor.fetchall()

def fetch_long_running_reports(cursor):
    cursor.execute("""
        SELECT id, report_name, status, start_ts, expected_duration_mins,
               ROUND((SYSTIMESTAMP - start_ts) * 24 * 60, 2) AS elapsed_mins
        FROM ReportLog
        WHERE status = 'RUNNING'
          AND end_ts IS NULL
          AND expected_duration_mins IS NOT NULL
          AND (SYSTIMESTAMP - start_ts) * 24 * 60 > expected_duration_mins
        ORDER BY start_ts
    """)
    return cursor.fetchall()

def fetch_failed_reports(cursor):
    cursor.execute("""
        SELECT id, report_name, status, start_ts, end_ts, expected_duration_mins, error_message
        FROM ReportLog
        WHERE status = 'FAILED'
        ORDER BY start_ts DESC
    """)
    return cursor.fetchall()
```

---

## 4.2 Anomaly detection script (poll and print)

**File to create:** `agent/monitor.py`

**Exact content:**

```python
import sys
import os
import time

# Ensure project root is on path when running as script
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from agent.db import (
    get_connection,
    fetch_long_running_batches,
    fetch_failed_batches,
    fetch_long_running_reports,
    fetch_failed_reports,
)

POLL_INTERVAL_SEC = 30

def run_once():
    conn = get_connection()
    try:
        cur = conn.cursor()
        anomalies = []

        for row in fetch_long_running_batches(cur):
            anomalies.append({
                "source": "BatchLog",
                "type": "long_running",
                "id": row[0],
                "name": row[1],
                "status": row[2],
                "start_ts": row[3],
                "expected_mins": row[4],
                "elapsed_mins": row[5],
            })

        for row in fetch_failed_batches(cur):
            anomalies.append({
                "source": "BatchLog",
                "type": "failed",
                "id": row[0],
                "name": row[1],
                "status": row[2],
                "start_ts": row[3],
                "end_ts": row[4],
                "expected_mins": row[5],
                "error_message": row[6],
            })

        for row in fetch_long_running_reports(cur):
            anomalies.append({
                "source": "ReportLog",
                "type": "long_running",
                "id": row[0],
                "name": row[1],
                "status": row[2],
                "start_ts": row[3],
                "expected_mins": row[4],
                "elapsed_mins": row[5],
            })

        for row in fetch_failed_reports(cur):
            anomalies.append({
                "source": "ReportLog",
                "type": "failed",
                "id": row[0],
                "name": row[1],
                "status": row[2],
                "start_ts": row[3],
                "end_ts": row[4],
                "expected_mins": row[5],
                "error_message": row[6],
            })

        return anomalies
    finally:
        conn.close()

def main():
    print("Monitor started. Polling every", POLL_INTERVAL_SEC, "seconds. Ctrl+C to stop.")
    while True:
        try:
            anomalies = run_once()
            if anomalies:
                for a in anomalies:
                    print("[ANOMALY]", a)
            else:
                print(".", end="", flush=True)
        except Exception as e:
            print("Error:", e)
        time.sleep(POLL_INTERVAL_SEC)

if __name__ == "__main__":
    main()
```

---

## 4.3 Run and verify monitor

**From project root `hacathon/`:**

```bash
# Activate venv first
source venv/bin/activate   # or venv\Scripts\activate on Windows

# Run monitor (should list RECONCILIATION_BATCH and REGULATORY_EXPORT)
python -m agent.monitor
```

You should see one long-running batch and one failed report printed. Stop with `Ctrl+C`.

---

**Phase 4 checklist:** `agent/db.py` and `agent/monitor.py` run; anomaly rows are detected and printed.

---

# Phase 5: Bedrock agent (root cause analysis)

**Goal:** When an anomaly is found, build a prompt with anomaly details + AWR text + code repo snippets, call AWS Bedrock, and parse root cause + recommendations. Still no alerting; can print result.

**Duration (approx.):** 2–3 hours

---

## 5.1 Load AWS credentials from env file

**File to create:** `agent/aws_env.py`

**Exact content:**

```python
import os

def load_aws_env(env_file=None):
    if env_file is None:
        base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        env_file = os.path.join(base, "config", "aws_credentials.env")
    if not os.path.exists(env_file):
        return
    with open(env_file) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" in line:
                key, val = line.split("=", 1)
                os.environ[key.strip()] = val.strip()
```

Call `load_aws_env()` at the start of any script that uses boto3.

---

## 5.2 Bedrock invoke and prompt builder

**File to create:** `agent/bedrock_agent.py`

**Exact content:**

```python
import json
import os
import sys

# Project root
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from agent.aws_env import load_aws_env
load_aws_env()

import boto3

def read_file(path):
    base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    full = os.path.join(base, path)
    if not os.path.exists(full):
        return ""
    with open(full) as f:
        return f.read()

def build_user_message(anomaly, awr_text, code_snippets):
    parts = [
        "## Anomaly",
        json.dumps(anomaly, default=str, indent=2),
        "",
        "## AWR / Diagnostic (simulated)",
        awr_text,
        "",
        "## Relevant code snippets",
        code_snippets,
        "",
        "Based on the above, provide:",
        "1. ROOT_CAUSE: one short paragraph.",
        "2. RECOMMENDATIONS: bullet list of concrete fixes or optimizations.",
    ]
    return "\n".join(parts)

def invoke_bedrock(user_message, region=None):
    region = region or os.environ.get("AWS_DEFAULT_REGION", "us-east-1")
    client = boto3.client("bedrock-runtime", region_name=region)
    model_id = "anthropic.claude-3-haiku-20240307-v1:0"  # or anthropic.claude-3-5-sonnet-... if you have access
    system_prompt = (
        "You are an expert Oracle DBA and performance analyst. "
        "Given anomaly details from BatchLog/ReportLog, AWR/diagnostic output, and code snippets, "
        "identify the root cause and suggest specific fixes or optimizations. "
        "Be concise and actionable."
    )
    body = {
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": 1024,
        "system": system_prompt,
        "messages": [{"role": "user", "content": user_message}],
    }
    response = client.invoke_model(modelId=model_id, body=json.dumps(body))
    result = json.loads(response["body"].read())
    return result["content"][0]["text"]

def run_rca(anomaly):
    awr_text = read_file("awr_simulated/awr_sample.txt")
    code_snippets = read_file("db_scripts/batch_reconciliation.sql") + "\n\n" + read_file("db_scripts/report_regulatory_export.sql")
    user_message = build_user_message(anomaly, awr_text, code_snippets)
    return invoke_bedrock(user_message)
```

**Note:** If `anthropic.claude-3-haiku-20240307-v1:0` is not available in your region or account, use the exact model ID from Bedrock console (e.g. another Haiku or Sonnet).

---

## 5.3 Wire monitor to run RCA once per anomaly (no duplicate)

**File to create:** `agent/processed.py`

**Exact content** (in-memory set of processed anomaly keys; you can later replace with DB or file):

```python
_processed = set()

def key(anomaly):
    return (anomaly.get("source"), anomaly.get("id"), anomaly.get("type"))

def is_processed(anomaly):
    return key(anomaly) in _processed

def mark_processed(anomaly):
    _processed.add(key(anomaly))
```

---

## 5.4 Update monitor to call Bedrock and print RCA

**File to update:** `agent/monitor.py`

**Add at top (after existing imports):**

```python
from agent.bedrock_agent import run_rca
from agent.processed import is_processed, mark_processed
```

**Replace the block that does `if anomalies:` with:**

```python
if anomalies:
    for a in anomalies:
        if is_processed(a):
            continue
        print("\n[ANOMALY]", a)
        try:
            rca_text = run_rca(a)
            print("[RCA]\n", rca_text)
            mark_processed(a)
        except Exception as e:
            print("[RCA ERROR]", e)
```

So the full `main()` loop in `agent/monitor.py` should look like this (replace the existing `if anomalies:` block accordingly):

```python
def main():
    print("Monitor started. Polling every", POLL_INTERVAL_SEC, "seconds. Ctrl+C to stop.")
    while True:
        try:
            anomalies = run_once()
            if anomalies:
                for a in anomalies:
                    if is_processed(a):
                        continue
                    print("\n[ANOMALY]", a)
                    try:
                        rca_text = run_rca(a)
                        print("[RCA]\n", rca_text)
                        mark_processed(a)
                    except Exception as e:
                        print("[RCA ERROR]", e)
            else:
                print(".", end="", flush=True)
        except Exception as e:
            print("Error:", e)
        time.sleep(POLL_INTERVAL_SEC)
```

---

## 5.5 Run end-to-end (monitor + Bedrock RCA)

**From project root, with venv active and `config/aws_credentials.env` set:**

```bash
python -m agent.monitor
```

On first poll you should see the two anomalies and two RCA outputs from Bedrock. Then they are marked processed and not repeated.

---

**Phase 5 checklist:** Bedrock is invoked with anomaly + AWR + code; RCA text is printed in console.

---

# Phase 6: Alerting (two-stage)

**Goal:** (1) Immediate alert when an anomaly is detected; (2) Second alert after RCA with AWR snippet, root cause, and recommendations. Use AWS SNS (email) within free tier.

**Duration (approx.):** 1–2 hours

---

## 6.1 Create SNS topic and email subscription (AWS Console)

1. **SNS → Topics → Create topic.**  
   - Type: Standard  
   - Name: `creditplus-anomaly-alerts`  
2. **Create subscription:**  
   - Topic → Create subscription  
   - Protocol: **Email**  
   - Endpoint: your email  
   - Create subscription.  
3. **Confirm subscription:** Check your inbox and click the confirmation link.  
4. **Note the Topic ARN** (e.g. `arn:aws:sns:us-east-1:123456789012:creditplus-anomaly-alerts`).  
5. **IAM:** Ensure the IAM user that has Bedrock access also has `sns:Publish` on this topic (e.g. attach `AmazonSNSFullAccess` or a policy that allows `sns:Publish` for this ARN).

---

## 6.2 Add SNS config

**File to create or update:** `config/paths.json` – add SNS topic ARN (replace with your ARN):

```json
{
  "project_root": ".",
  "awr_simulated_dir": "awr_simulated",
  "awr_sample_file": "awr_simulated/awr_sample.txt",
  "code_repo_dir": "db_scripts",
  "alerts_dir": "alerts",
  "sns_topic_arn": "arn:aws:sns:us-east-1:YOUR_ACCOUNT_ID:creditplus-anomaly-alerts"
}
```

---

## 6.3 Alert helper (SNS + local file)

**File to create:** `agent/alerting.py`

**Exact content:**

```python
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from agent.aws_env import load_aws_env
load_aws_env()

import boto3

def load_paths():
    base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    with open(os.path.join(base, "config", "paths.json")) as f:
        return json.load(f)

def send_immediate_alert(anomaly):
    subject = "[CreditPlus] Anomaly: {} - {} (id={})".format(
        anomaly.get("type", ""),
        anomaly.get("name", anomaly.get("report_name", "?")),
        anomaly.get("id"),
    )
    body = "Anomaly detected:\n\n" + json.dumps(anomaly, default=str, indent=2)
    _publish(subject, body)
    _write_local("immediate", subject, body)

def send_rca_alert(anomaly, awr_snippet, rca_text):
    subject = "[CreditPlus] RCA: {} (id={})".format(
        anomaly.get("name", anomaly.get("report_name", "?")),
        anomaly.get("id"),
    )
    body = (
        "Anomaly: " + json.dumps(anomaly, default=str, indent=2) + "\n\n"
        "--- AWR snippet ---\n" + (awr_snippet or "") + "\n\n"
        "--- Root cause and recommendations ---\n" + (rca_text or "")
    )
    _publish(subject, body)
    _write_local("rca", subject, body)

def _publish(subject, body):
    paths = load_paths()
    arn = paths.get("sns_topic_arn")
    if not arn:
        print("(SNS not configured; skipping publish)")
        return
    try:
        boto3.client("sns").publish(TopicArn=arn, Subject=subject, Message=body)
    except Exception as e:
        print("SNS publish failed:", e)

def _write_local(kind, subject, body):
    paths = load_paths()
    alerts_dir = paths.get("alerts_dir", "alerts")
    base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out_dir = os.path.join(base, alerts_dir)
    os.makedirs(out_dir, exist_ok=True)
    import time
    fname = os.path.join(out_dir, "{}_{}.txt".format(kind, int(time.time())))
    with open(fname, "w") as f:
        f.write(subject + "\n\n" + body)
```

---

## 6.4 Wire monitor to send Alert 1 and Alert 2

**In `agent/monitor.py`:**

1. **Add imports:**

```python
from agent.alerting import send_immediate_alert, send_rca_alert
from agent.bedrock_agent import read_file
```

2. **When you detect a new anomaly (before RCA):** call `send_immediate_alert(a)`.  
3. **After RCA:** call `send_rca_alert(a, awr_snippet, rca_text)`.  
   - `awr_snippet` can be the first 2000 chars of AWR: `read_file("awr_simulated/awr_sample.txt")[:2000]`.  
   - `rca_text` is the string returned from `run_rca(a)`.

**Concrete changes in `agent/monitor.py`:**

- After `print("\n[ANOMALY]", a)` add: `send_immediate_alert(a)`  
- After `rca_text = run_rca(a)` add:  
  `awr_snippet = read_file("awr_simulated/awr_sample.txt")[:2000]`  
  `send_rca_alert(a, awr_snippet, rca_text)`  
  and then `mark_processed(a)`.

---

## 6.5 Verify emails

Run `python -m agent.monitor` again; for each new anomaly you should get two emails (immediate + RCA). Also check `alerts/` for `.txt` files.

---

**Phase 6 checklist:** SNS topic created and subscribed; immediate and RCA alerts sent by email and written to `alerts/`.

---

### Appendix: Full `agent/monitor.py` (with alerting)

After completing 6.4, your `agent/monitor.py` should look like this (copy-paste to replace entire file if needed):

```python
import sys
import os
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from agent.db import (
    get_connection,
    fetch_long_running_batches,
    fetch_failed_batches,
    fetch_long_running_reports,
    fetch_failed_reports,
)
from agent.bedrock_agent import run_rca, read_file
from agent.processed import is_processed, mark_processed
from agent.alerting import send_immediate_alert, send_rca_alert

POLL_INTERVAL_SEC = 30

def run_once():
    conn = get_connection()
    try:
        cur = conn.cursor()
        anomalies = []
        for row in fetch_long_running_batches(cur):
            anomalies.append({
                "source": "BatchLog", "type": "long_running",
                "id": row[0], "name": row[1], "status": row[2], "start_ts": row[3],
                "expected_mins": row[4], "elapsed_mins": row[5],
            })
        for row in fetch_failed_batches(cur):
            anomalies.append({
                "source": "BatchLog", "type": "failed",
                "id": row[0], "name": row[1], "status": row[2], "start_ts": row[3],
                "end_ts": row[4], "expected_mins": row[5], "error_message": row[6],
            })
        for row in fetch_long_running_reports(cur):
            anomalies.append({
                "source": "ReportLog", "type": "long_running",
                "id": row[0], "name": row[1], "status": row[2], "start_ts": row[3],
                "expected_mins": row[4], "elapsed_mins": row[5],
            })
        for row in fetch_failed_reports(cur):
            anomalies.append({
                "source": "ReportLog", "type": "failed",
                "id": row[0], "name": row[1], "status": row[2], "start_ts": row[3],
                "end_ts": row[4], "expected_mins": row[5], "error_message": row[6],
            })
        return anomalies
    finally:
        conn.close()

def main():
    print("Monitor started. Polling every", POLL_INTERVAL_SEC, "seconds. Ctrl+C to stop.")
    while True:
        try:
            anomalies = run_once()
            if anomalies:
                for a in anomalies:
                    if is_processed(a):
                        continue
                    print("\n[ANOMALY]", a)
                    send_immediate_alert(a)
                    try:
                        rca_text = run_rca(a)
                        print("[RCA]\n", rca_text)
                        awr_snippet = read_file("awr_simulated/awr_sample.txt")[:2000]
                        send_rca_alert(a, awr_snippet, rca_text)
                        mark_processed(a)
                    except Exception as e:
                        print("[RCA ERROR]", e)
            else:
                print(".", end="", flush=True)
        except Exception as e:
            print("Error:", e)
        time.sleep(POLL_INTERVAL_SEC)

if __name__ == "__main__":
    main()
```

---

# Phase 7: Oracle MCP (optional integration)

**Goal:** Allow the AI to “query” the database via Oracle SQLcl MCP so that context can include live data (e.g. “describe BatchLog”, “last 5 batches”). This phase is optional for a minimal demo.

**Duration (approx.):** 1–2 hours

---

## 7.1 Start SQLcl MCP server

From terminal (replace with your SQLcl path):

```bash
/path/to/sqlcl/bin/sql -mcp
```

Or configure your MCP client (e.g. Cline in VS Code) to run `sql -mcp` with the saved connection so the AI can run SQL.

---

## 7.2 Optional: call MCP from agent

If you use an MCP client library in Python (e.g. `mcp` package), you can:

1. Start SQLcl MCP as subprocess or connect to it.  
2. Send a tool call like “Run SQL: SELECT * FROM BatchLog WHERE id = :id” with the anomaly id.  
3. Append the result to the user message in `build_user_message()`.

For a minimal demo, Phase 5 (static AWR + code files) is enough; MCP can be Phase 7 or post-demo.

---

# Phase 8: Demo day checklist

- [ ] Docker Oracle running; `BatchLog` / `ReportLog` have dummy data including one long-running and one failed.  
- [ ] `config/aws_credentials.env` and `config/paths.json` (with SNS ARN) in place.  
- [ ] Venv activated; `python -m agent.monitor` runs without errors.  
- [ ] Trigger: ensure at least one RUNNING batch exceeds expected time (or insert one).  
- [ ] Show Alert 1 (immediate) in inbox and/or `alerts/immediate_*.txt`.  
- [ ] Show Alert 2 (RCA) with AWR snippet, root cause, and recommendations.  
- [ ] Optional: show Oracle MCP returning live data in the agent context.

---

# Summary: what we do in each phase

| Phase | What we do (minute detail) |
|-------|-----------------------------|
| **1** | Create folders; AWS account + Bedrock + IAM user; `config/aws_credentials.env`; install Docker, Java, SQLcl, Python venv and deps; optional billing alert. |
| **2** | Run Oracle in Docker; create `BatchLog` and `ReportLog` with full DDL; insert completed, long-running, and failed rows; verify with SELECT. |
| **3** | Create `awr_simulated/awr_sample.txt`; create `db_scripts/batch_reconciliation.sql` and `report_regulatory_export.sql`; create `config/paths.json`. |
| **4** | Implement `agent/db.py` (connection + fetch queries) and `agent/monitor.py` (poll loop, anomaly detection, print). |
| **5** | Implement `agent/aws_env.py`, `agent/bedrock_agent.py` (read AWR/code, build prompt, invoke Bedrock), `agent/processed.py`; wire monitor to run RCA once per anomaly and print. |
| **6** | Create SNS topic and email subscription; add `sns_topic_arn` to config; implement `agent/alerting.py`; from monitor send Alert 1 on detection and Alert 2 after RCA (with AWR snippet + RCA text). |
| **7** | Optional: run SQLcl MCP and optionally integrate MCP into agent context. |
| **8** | Run through demo checklist and present. |

End of plan.
