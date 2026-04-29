"""
Phase B: Live diagnostic report from Oracle V$SQL, V$SQL_PLAN, V$SQLTEXT, V$SESSION_EVENT.
Replaces hardcoded AWR for RCA. Requires SELECT on V_$SQL, V_$SQLTEXT, V_$SQL_PLAN, V_$SESSION_EVENT.

When a batch/report runs, Oracle stores every executed SQL in the shared pool (V$SQL) and
updates LAST_ACTIVE_TIME. We query V$SQL for the anomaly's time window (start_ts to end_ts
or SYSDATE). So the batch's own SQL (SELECT/INSERT/UPDATE from the PL/SQL) appears in
the result; we do not send empty diagnostics as long as the batch has run any SQL and
the cursor has not been aged out (unlikely during an active long-running job).
"""
from agent.db import get_connection


def _to_oracle_ts_str(ts):
    """
    Convert start_ts/end_ts to a string Oracle TO_DATE can parse ('YYYY-MM-DD HH24:MI:SS').
    Avoids Python datetime binding issues (timezone/type) so V$SQL time window returns rows.
    """
    if ts is None:
        return None
    if hasattr(ts, "strftime"):
        return ts.strftime("%Y-%m-%d %H:%M:%S")
    s = str(ts).strip()
    if not s:
        return None
    if len(s) >= 19:
        return s[:19].replace("T", " ")
    return s


def fetch_top_sql(conn, start_ts, end_ts, top_n=10):
    """Return list of (sql_id, elapsed_time, executions, buffer_gets, disk_reads, last_active).
    Uses TO_DATE with string timestamps so Oracle compares DATE to DATE in session timezone;
    binding Python datetime caused no rows due to type/timezone mismatch."""
    start_str = _to_oracle_ts_str(start_ts)
    if not start_str:
        return []
    end_str = _to_oracle_ts_str(end_ts)
    cur = conn.cursor()
    cur.execute("""
        SELECT SQL_ID, ELAPSED_TIME, EXECUTIONS, BUFFER_GETS, DISK_READS,
               TO_CHAR(LAST_ACTIVE_TIME, 'YYYY-MM-DD HH24:MI:SS') AS LAST_ACTIVE
        FROM V$SQL
        WHERE LAST_ACTIVE_TIME >= TO_DATE(:start_ts_str, 'YYYY-MM-DD HH24:MI:SS')
          AND LAST_ACTIVE_TIME <= CASE WHEN :end_ts_str IS NULL THEN SYSDATE ELSE TO_DATE(:end_ts_str, 'YYYY-MM-DD HH24:MI:SS') END
          AND EXECUTIONS > 0
          AND SQL_ID IS NOT NULL
        ORDER BY ELAPSED_TIME DESC
        FETCH FIRST :top_n ROWS ONLY
    """, start_ts_str=start_str, end_ts_str=end_str, top_n=top_n)
    return cur.fetchall()


def fetch_sql_text(conn, sql_id):
    """Return full SQL text for sql_id from V$SQLTEXT."""
    cur = conn.cursor()
    try:
        cur.execute("""
            SELECT SQL_TEXT FROM V$SQLTEXT
            WHERE SQL_ID = :sql_id
            ORDER BY PIECE
        """, sql_id=sql_id)
        rows = cur.fetchall()
        return "".join(r[0] for r in rows) if rows else ""
    except Exception:
        return ""


def fetch_sql_plan(conn, sql_id):
    """Return execution plan lines for sql_id from V$SQL_PLAN."""
    cur = conn.cursor()
    try:
        cur.execute("""
            SELECT ID, OPERATION, OPTIONS, OBJECT_OWNER, OBJECT_NAME, COST, CARDINALITY
            FROM V$SQL_PLAN
            WHERE SQL_ID = :sql_id
            ORDER BY ID
        """, sql_id=sql_id)
        return cur.fetchall()
    except Exception:
        return []


def fetch_session_waits(conn, start_ts, end_ts):
    """Return current or recent session wait events if available (optional)."""
    cur = conn.cursor()
    try:
        cur.execute("""
            SELECT EVENT, WAIT_CLASS, TOTAL_WAITS, TIME_WAITED_MICRO
            FROM V$SESSION_EVENT
            WHERE SID = SYS_CONTEXT('USERENV','SID')
            ORDER BY TIME_WAITED_MICRO DESC
            FETCH FIRST 10 ROWS ONLY
        """)
        return cur.fetchall()
    except Exception:
        return []


def build_diagnostic_report(anomaly):
    """
    Build a text diagnostic report for the anomaly time window.
    anomaly must have start_ts (datetime); end_ts optional (None for long-running).
    Returns report string. On permission/error, returns short fallback message.
    """
    start_ts = anomaly.get("start_ts")
    end_ts = anomaly.get("end_ts")
    if not start_ts:
        return "(No start time for anomaly; cannot query V$SQL time window.)"

    conn = get_connection()
    try:
        top = fetch_top_sql(conn, start_ts, end_ts, top_n=10)
        if not top:
            return (
                "---------------------------------------------\n"
                "LIVE DIAGNOSTIC (V$SQL)\n"
                "---------------------------------------------\n"
                "Time window: {} to {}\n"
                "No SQL rows found in V$SQL for this window.\n"
                "(Cursor may have been aged out or user lacks SELECT on V$SQL.)\n"
            ).format(start_ts, end_ts or "SYSDATE")

        lines = [
            "=============================================",
            "LIVE DIAGNOSTIC REPORT (V$SQL / V$SQL_PLAN)",
            "=============================================",
            "Anomaly window: start_ts={}  end_ts={}".format(start_ts, end_ts or "current"),
            "",
            "---------------------------------------------",
            "TOP SQL BY ELAPSED TIME",
            "---------------------------------------------",
        ]
        for row in top:
            sql_id, elapsed, execs, buf_gets, disk_reads, last_active = row
            elapsed_sec = (elapsed or 0) / 1_000_000  # Oracle stores in microseconds
            lines.append(
                "SQL_ID: {}  Elapsed(s): {:.2f}  Executions: {}  "
                "Buffer gets: {}  Disk reads: {}  Last active: {}".format(
                    sql_id, elapsed_sec, execs or 0, buf_gets or 0, disk_reads or 0, last_active or ""
                )
            )

        for row in top[:5]:  # detail for top 5
            sql_id = row[0]
            lines.append("")
            lines.append("--- SQL_ID: {} ---".format(sql_id))
            text = fetch_sql_text(conn, sql_id)
            if text:
                lines.append(text.strip()[:2000])  # cap length
            plan_rows = fetch_sql_plan(conn, sql_id)
            if plan_rows:
                lines.append("")
                lines.append("Execution plan:")
                for pl in plan_rows:
                    id_, op, opt, owner, obj, cost, card = (pl[0], pl[1], pl[2] or "", pl[3] or "", pl[4] or "", pl[5], pl[6])
                    lines.append("  {} | {} {} | {} {} | cost={} card={}".format(id_, op, opt, owner, obj, cost, card))

        # Use V$SESSION_EVENT (granted) for wait events of the diagnostic session
        wait_rows = fetch_session_waits(conn, start_ts, end_ts)
        if wait_rows:
            lines.append("")
            lines.append("---------------------------------------------")
            lines.append("SESSION WAIT EVENTS (V$SESSION_EVENT, diagnostic session)")
            lines.append("---------------------------------------------")
            for row in wait_rows:
                event, wait_class, total_waits, time_waited_micro = (row[0] or "", row[1] or "", row[2] or 0, row[3] or 0)
                time_sec = time_waited_micro / 1_000_000
                lines.append("  {} | {} | Waits: {} | Time(s): {:.2f}".format(event, wait_class, total_waits, time_sec))

        return "\n".join(lines)
    except Exception as e:
        return (
            "---------------------------------------------\n"
            "LIVE DIAGNOSTIC (unavailable)\n"
            "---------------------------------------------\n"
            "Error: {}.\n"
            "For live diagnostics, run as SYSDBA: @scripts/grant_v_views.sql\n"
        ).format(str(e))
    finally:
        conn.close()


def fetch_diagnostic_report(anomaly):
    """
    Public API: fetch live diagnostic report for this anomaly.
    Same as build_diagnostic_report (alias for clarity).
    """
    return build_diagnostic_report(anomaly)


def get_top_sql_ids(anomaly, top_n=5):
    """
    Return list of SQL_IDs (strings) for the anomaly time window, from V$SQL.
    Used by Phase C code crawling. Returns [] on error or if V$ not accessible.
    """
    start_ts = anomaly.get("start_ts")
    end_ts = anomaly.get("end_ts")
    if not start_ts:
        return []
    try:
        conn = get_connection()
        try:
            rows = fetch_top_sql(conn, start_ts, end_ts, top_n=top_n)
            return [row[0] for row in rows if row[0]]
        finally:
            conn.close()
    except Exception:
        return []
