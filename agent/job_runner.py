"""
Run batches / reports by calling PL/SQL packages through PKG_JOB_RUNNER.
All times in SECONDS. avg_secs = typical runtime; expected_secs = avg + 10% buffer
(used for long-running detection: job is flagged when elapsed > expected).
"""
import math
import threading
from agent.db import get_connection

BATCH_REGISTRY = {
    "RECONCILIATION_BATCH": {"avg_secs": 60,  "label": "Reconciliation Batch"},
    "DAILY_SETTLEMENT":     {"avg_secs": 3,   "label": "Daily Settlement"},
    "FRAUD_CHECK_BATCH":    {"avg_secs": 40,  "label": "Fraud Check Batch"},
    "EOD_BALANCE_BATCH":    {"avg_secs": 3,   "label": "EOD Balance Batch"},
}

REPORT_REGISTRY = {
    "REGULATORY_EXPORT":  {"avg_secs": 15, "label": "Regulatory Export"},
    "TXN_SYNC":           {"avg_secs": 3,  "label": "Transaction Sync"},
    "MERCHANT_REPORT":    {"avg_secs": 30, "label": "Merchant Report"},
    "DAILY_SUMMARY":      {"avg_secs": 3,  "label": "Daily Summary"},
}


def _expected_secs(avg_secs):
    """Expected = avg + 10% buffer. Job is long-running when elapsed > this."""
    return int(math.ceil(float(avg_secs) * 1.1))


def run_batch_async(batch_name):
    info = BATCH_REGISTRY.get(batch_name)
    if not info:
        raise ValueError(f"Unknown batch: {batch_name}")
    avg = info["avg_secs"]
    expected = _expected_secs(avg)

    conn = get_connection()
    cur = conn.cursor()
    job_id = cur.callfunc('PKG_JOB_RUNNER.START_BATCH', int, [batch_name, avg, expected])
    conn.close()

    def _execute():
        c = get_connection()
        try:
            c.cursor().callproc('PKG_JOB_RUNNER.EXEC_AND_FINISH_BATCH', [batch_name, job_id])
            c.commit()
        except Exception as e:
            print(f"[job_runner] batch {batch_name} job_id={job_id} error: {e}")
        finally:
            c.close()

    threading.Thread(target=_execute, daemon=True).start()
    return job_id


def run_report_async(report_name):
    info = REPORT_REGISTRY.get(report_name)
    if not info:
        raise ValueError(f"Unknown report: {report_name}")
    avg = info["avg_secs"]
    expected = _expected_secs(avg)

    conn = get_connection()
    cur = conn.cursor()
    job_id = cur.callfunc('PKG_JOB_RUNNER.START_REPORT', int, [report_name, avg, expected])
    conn.close()

    def _execute():
        c = get_connection()
        try:
            c.cursor().callproc('PKG_JOB_RUNNER.EXEC_AND_FINISH_REPORT', [report_name, job_id])
            c.commit()
        except Exception as e:
            print(f"[job_runner] report {report_name} job_id={job_id} error: {e}")
        finally:
            c.close()

    threading.Thread(target=_execute, daemon=True).start()
    return job_id


def get_batch_info(job_id):
    conn = get_connection()
    try:
        cur = conn.cursor()
        cur.execute(
            "SELECT job_id, batch_name, status, start_ts, end_ts, "
            "expected_duration_secs, avg_duration_secs, error_message "
            "FROM BatchLog WHERE job_id = :1", [job_id])
        row = cur.fetchone()
        if not row:
            return None
        return {
            "id": row[0], "batch_name": row[1], "status": row[2],
            "start_ts": row[3].isoformat() if row[3] else None,
            "end_ts": row[4].isoformat() if row[4] else None,
            "expected_secs": row[5], "avg_secs": row[6], "error_message": row[7],
        }
    finally:
        conn.close()


def get_report_info(job_id):
    conn = get_connection()
    try:
        cur = conn.cursor()
        cur.execute(
            "SELECT job_id, report_name, status, start_ts, end_ts, "
            "expected_duration_secs, avg_duration_secs, error_message "
            "FROM ReportLog WHERE job_id = :1", [job_id])
        row = cur.fetchone()
        if not row:
            return None
        return {
            "id": row[0], "report_name": row[1], "status": row[2],
            "start_ts": row[3].isoformat() if row[3] else None,
            "end_ts": row[4].isoformat() if row[4] else None,
            "expected_secs": row[5], "avg_secs": row[6], "error_message": row[7],
        }
    finally:
        conn.close()


def fail_batch(job_id: int, reason: str = "Failed by operator"):
    conn = get_connection()
    try:
        conn.cursor().callproc("PKG_JOB_RUNNER.REQUEST_CANCEL_BATCH", [job_id, reason])
        conn.commit()
    finally:
        conn.close()


def fail_report(job_id: int, reason: str = "Failed by operator"):
    conn = get_connection()
    try:
        conn.cursor().callproc("PKG_JOB_RUNNER.REQUEST_CANCEL_REPORT", [job_id, reason])
        conn.commit()
    finally:
        conn.close()
