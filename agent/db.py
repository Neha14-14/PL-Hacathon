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
        SELECT job_id, batch_name, status, start_ts, expected_duration_secs,
               ROUND((CAST(SYSTIMESTAMP AS DATE) - CAST(start_ts AS DATE)) * 86400, 2) AS elapsed_secs
        FROM BatchLog
        WHERE status = 'RUNNING'
          AND end_ts IS NULL
          AND expected_duration_secs IS NOT NULL
          AND (CAST(SYSTIMESTAMP AS DATE) - CAST(start_ts AS DATE)) * 86400 > expected_duration_secs
        ORDER BY start_ts DESC
    """)
    return cursor.fetchall()


def fetch_failed_batches(cursor):
    try:
        cursor.execute("""
            SELECT job_id, batch_name, status, start_ts, end_ts, expected_duration_secs, error_message,
                   NVL(cancel_requested, 0) AS cancel_requested
            FROM BatchLog
            WHERE status = 'FAILED'
            ORDER BY start_ts DESC
        """)
        return cursor.fetchall()
    except Exception:
        cursor.execute("""
            SELECT job_id, batch_name, status, start_ts, end_ts, expected_duration_secs, error_message
            FROM BatchLog
            WHERE status = 'FAILED'
            ORDER BY start_ts DESC
        """)
        return [row + (0,) for row in cursor.fetchall()]


def fetch_long_running_reports(cursor):
    cursor.execute("""
        SELECT job_id, report_name, status, start_ts, expected_duration_secs,
               ROUND((CAST(SYSTIMESTAMP AS DATE) - CAST(start_ts AS DATE)) * 86400, 2) AS elapsed_secs
        FROM ReportLog
        WHERE status = 'RUNNING'
          AND end_ts IS NULL
          AND expected_duration_secs IS NOT NULL
          AND (CAST(SYSTIMESTAMP AS DATE) - CAST(start_ts AS DATE)) * 86400 > expected_duration_secs
        ORDER BY start_ts DESC
    """)
    return cursor.fetchall()


def fetch_failed_reports(cursor):
    try:
        cursor.execute("""
            SELECT job_id, report_name, status, start_ts, end_ts, expected_duration_secs, error_message,
                   NVL(cancel_requested, 0) AS cancel_requested
            FROM ReportLog
            WHERE status = 'FAILED'
            ORDER BY start_ts DESC
        """)
        return cursor.fetchall()
    except Exception:
        cursor.execute("""
            SELECT job_id, report_name, status, start_ts, end_ts, expected_duration_secs, error_message
            FROM ReportLog
            WHERE status = 'FAILED'
            ORDER BY start_ts DESC
        """)
        return [row + (0,) for row in cursor.fetchall()]
