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
from agent.bedrock_agent import run_rca
from agent.processed import is_processed, mark_processed
from agent.alerting import send_immediate_alert, send_rca_alert

POLL_INTERVAL_SEC = 5


def _sleep_until_stop_or_interval(seconds):
    try:
        from agent.state import get_stop_requested
    except Exception:
        time.sleep(seconds)
        return
    step = 1.0
    elapsed = 0.0
    while elapsed < seconds:
        if get_stop_requested():
            return
        time.sleep(min(step, seconds - elapsed))
        elapsed += step


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
                "expected_secs": row[4],
                "elapsed_secs": row[5],
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
                "expected_secs": row[5],
                "error_message": row[6],
                "cancel_requested": row[7] if len(row) > 7 else 0,
            })

        for row in fetch_long_running_reports(cur):
            anomalies.append({
                "source": "ReportLog",
                "type": "long_running",
                "id": row[0],
                "name": row[1],
                "status": row[2],
                "start_ts": row[3],
                "expected_secs": row[4],
                "elapsed_secs": row[5],
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
                "expected_secs": row[5],
                "error_message": row[6],
                "cancel_requested": row[7] if len(row) > 7 else 0,
            })

        return anomalies
    finally:
        conn.close()


def main():
    try:
        try:
            from agent.state import clear_stop, set_monitoring_active
            clear_stop()
            set_monitoring_active(True)
        except Exception:
            pass
        print("Monitor started. Polling every", POLL_INTERVAL_SEC, "seconds.")
        while True:
            try:
                from agent.state import get_stop_requested
                if get_stop_requested():
                    print("\n[Monitor] Stop requested, exiting.")
                    break
            except Exception:
                pass
            try:
                anomalies = run_once()
                if anomalies:
                    for a in anomalies:
                        if is_processed(a):
                            continue
                        # Do not trigger alert/RCA for operator-cancelled jobs (user clicked Fail).
                        if a.get("type") == "failed":
                            cancel = a.get("cancel_requested") in (1, 1.0)
                            err = (a.get("error_message") or "").lower()
                            if cancel or "cancelled" in err or "operator" in err or "failed by operator" in err:
                                mark_processed(a)
                                continue
                        print("\n[ANOMALY]", a)
                        send_immediate_alert(a)
                        try:
                            try:
                                from agent.state import set_rca_loading, set_last_rca, append_rca
                                set_rca_loading(True)
                            except Exception:
                                pass
                            rca_text, awr_snippet = run_rca(a)
                            print("[RCA]\n", rca_text)
                            try:
                                set_last_rca(a, rca_text)
                                append_rca(a, rca_text)
                            except Exception:
                                pass
                            send_rca_alert(a, (awr_snippet or "")[:2000], rca_text)
                            mark_processed(a)
                        except Exception as e:
                            print("[RCA ERROR]", e)
                        finally:
                            try:
                                from agent.state import set_rca_loading
                                set_rca_loading(False)
                            except Exception:
                                pass
                else:
                    print(".", end="", flush=True)
            except Exception as e:
                print("Error:", e)
            _sleep_until_stop_or_interval(POLL_INTERVAL_SEC)
    finally:
        try:
            from agent.state import set_monitoring_active
            set_monitoring_active(False)
        except Exception:
            pass


if __name__ == "__main__":
    main()
