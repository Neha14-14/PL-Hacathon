"""
FastAPI dashboard for Resilient Credit+ Guardian.
Monitors BatchLog/ReportLog, triggers RCA via Bedrock, and manages jobs.
Run: uvicorn web.main:app --reload
"""
import sys, os, json, threading

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles

app = FastAPI(title="Resilient Credit+ Guardian")

WEB_DIR = os.path.dirname(os.path.abspath(__file__))
_monitor_thread = None
_monitor_running = False


@app.on_event("startup")
def _startup_cleanup():
    try:
        from agent.db import get_connection
        from agent.state import clear_session
        clear_session()
        _COL_CACHE.clear()
        conn = get_connection()
        try:
            cur = conn.cursor()
            cur.execute("DELETE FROM BatchLog")
            cur.execute("DELETE FROM ReportLog")
            try:
                cur.execute("BEGIN EXECUTE IMMEDIATE 'DROP SEQUENCE BATCH_JOB_ID_SEQ'; EXCEPTION WHEN OTHERS THEN NULL; END;")
                cur.execute("BEGIN EXECUTE IMMEDIATE 'DROP SEQUENCE REPORT_JOB_ID_SEQ'; EXCEPTION WHEN OTHERS THEN NULL; END;")
                cur.execute("CREATE SEQUENCE BATCH_JOB_ID_SEQ START WITH 1000 INCREMENT BY 1 NOCACHE")
                cur.execute("CREATE SEQUENCE REPORT_JOB_ID_SEQ START WITH 1000 INCREMENT BY 1 NOCACHE")
            except Exception:
                pass
            conn.commit()
            print("[startup] BatchLog & ReportLog cleared, sequences reset to 1000")
        finally:
            conn.close()
    except Exception as e:
        print(f"[startup] cleanup error (non-fatal): {e}")


def _row_to_dict(cursor, row):
    cols = [d[0] for d in cursor.description]
    d = dict(zip(cols, row))
    for k, v in list(d.items()):
        if hasattr(v, "isoformat"):
            d[k] = v.isoformat()
    return d


_COL_CACHE = {}

def _detect_columns(cur, table):
    """Cache which optional columns exist in the table."""
    if table in _COL_CACHE:
        return _COL_CACHE[table]
    cur.execute(
        "SELECT column_name FROM user_tab_columns WHERE table_name = :1",
        [table.upper()]
    )
    cols = {r[0] for r in cur.fetchall()}
    _COL_CACHE[table] = cols
    return cols

def _safe_log_query(cur, table, name_col):
    cols = _detect_columns(cur, table)
    id_expr = "job_id" if "JOB_ID" in cols else "id"
    avg_expr = (
        "avg_duration_secs" if "AVG_DURATION_SECS" in cols
        else "avg_duration_mins * 60" if "AVG_DURATION_MINS" in cols
        else "NULL"
    )
    exp_expr = (
        "expected_duration_secs" if "EXPECTED_DURATION_SECS" in cols
        else "expected_duration_mins * 60" if "EXPECTED_DURATION_MINS" in cols
        else "NULL"
    )
    # Duration: for completed jobs (end_ts - start_ts); for RUNNING (SYSTIMESTAMP - start_ts). Server-computed so no timezone issues.
    duration_expr = (
        "CASE WHEN end_ts IS NOT NULL THEN ROUND((CAST(end_ts AS DATE) - CAST(start_ts AS DATE)) * 86400, 0) "
        "ELSE ROUND((CAST(SYSTIMESTAMP AS DATE) - CAST(start_ts AS DATE)) * 86400, 0) END"
        if "END_TS" in cols and "START_TS" in cols else "NULL"
    )
    cur.execute(f"""
        SELECT
            {id_expr}       AS id,
            {name_col}      AS name,
            status,
            start_ts        AS start_time,
            end_ts          AS end_time,
            {avg_expr}      AS avg_secs,
            {exp_expr}      AS expected_secs,
            {duration_expr} AS duration_secs,
            error_message
        FROM {table}
        ORDER BY start_ts DESC
    """)
    return [_row_to_dict(cur, r) for r in cur.fetchall()]


@app.get("/api/batchlog")
def api_batchlog():
    try:
        from agent.db import get_connection
        conn = get_connection()
        try:
            cur = conn.cursor()
            return json.loads(json.dumps(_safe_log_query(cur, "BatchLog", "batch_name"), default=str))
        finally:
            conn.close()
    except Exception as e:
        return []


@app.get("/api/reportlog")
def api_reportlog():
    try:
        from agent.db import get_connection
        conn = get_connection()
        try:
            cur = conn.cursor()
            return json.loads(json.dumps(_safe_log_query(cur, "ReportLog", "report_name"), default=str))
        finally:
            conn.close()
    except Exception as e:
        return []


@app.get("/api/status")
def api_status():
    from agent.state import get_status
    s = get_status()
    if s.get("last_rca") and "anomaly" in s["last_rca"]:
        s["last_rca"] = {
            "anomaly": s["last_rca"]["anomaly"],
            "rca_text": s["last_rca"].get("rca_text", ""),
        }
    return json.loads(json.dumps(s, default=str))


@app.post("/api/start-monitor")
def api_start_monitor():
    global _monitor_thread, _monitor_running
    if _monitor_running and _monitor_thread and _monitor_thread.is_alive():
        return {"status": "already_running"}
    try:
        from agent.state import clear_stop
        clear_stop()
        # Do NOT clear_session() here: same-session restart keeps alerts/RCA and avoids duplicate triggers.
    except Exception:
        pass
    def run():
        global _monitor_running
        _monitor_running = True
        try:
            from agent.monitor import main
            main()
        finally:
            _monitor_running = False
    _monitor_thread = threading.Thread(target=run, daemon=True)
    _monitor_thread.start()
    return {"status": "started"}


@app.post("/api/stop-monitor")
def api_stop_monitor():
    try:
        from agent.state import request_stop
        request_stop()
    except Exception:
        pass
    return {"status": "stop_requested"}


@app.get("/api/job-options")
def api_job_options():
    from agent.job_runner import BATCH_REGISTRY, REPORT_REGISTRY
    return {
        "batches": [{"id": k, "label": v["label"], "avg_secs": v["avg_secs"]} for k, v in BATCH_REGISTRY.items()],
        "reports": [{"id": k, "label": v["label"], "avg_secs": v["avg_secs"]} for k, v in REPORT_REGISTRY.items()],
    }


@app.post("/api/run-batch")
def api_run_batch(body: dict = None):
    from agent.job_runner import run_batch_async
    name = (body or {}).get("name")
    if not name:
        raise HTTPException(400, "Missing 'name'")
    try:
        job_id = run_batch_async(name)
        return {"job_id": job_id, "name": name, "type": "batch"}
    except ValueError as e:
        raise HTTPException(400, str(e))


@app.post("/api/run-report")
def api_run_report(body: dict = None):
    from agent.job_runner import run_report_async
    name = (body or {}).get("name")
    if not name:
        raise HTTPException(400, "Missing 'name'")
    try:
        job_id = run_report_async(name)
        return {"job_id": job_id, "name": name, "type": "report"}
    except ValueError as e:
        raise HTTPException(400, str(e))


@app.get("/api/job-status")
def api_job_status(type: str = None, id: int = Query(None)):
    if not type or id is None:
        raise HTTPException(400, "Need type=batch|report and id")
    if type == "batch":
        from agent.job_runner import get_batch_info
        info = get_batch_info(id)
    elif type == "report":
        from agent.job_runner import get_report_info
        info = get_report_info(id)
    else:
        raise HTTPException(400, "type must be batch or report")
    if not info:
        raise HTTPException(404, "Not found")
    return info


@app.post("/api/fail-job")
def api_fail_job(body: dict = None):
    body = body or {}
    typ = body.get("type")
    job_id = body.get("id")
    reason = body.get("reason") or "Failed by operator"
    if typ not in ("batch", "report") or job_id is None:
        raise HTTPException(400, "Need type=batch|report and id")
    try:
        if typ == "batch":
            from agent.job_runner import fail_batch
            fail_batch(int(job_id), reason)
        else:
            from agent.job_runner import fail_report
            fail_report(int(job_id), reason)
        return {"status": "failed", "type": typ, "id": int(job_id)}
    except Exception as e:
        raise HTTPException(500, str(e))


@app.get("/", response_class=HTMLResponse)
def index():
    with open(os.path.join(WEB_DIR, "static", "index.html")) as f:
        return f.read()


@app.get("/run", response_class=HTMLResponse)
def run_page():
    with open(os.path.join(WEB_DIR, "static", "run.html")) as f:
        return f.read()


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
