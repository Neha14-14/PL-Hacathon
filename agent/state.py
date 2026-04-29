"""
In-memory state for the dashboard UI. Updated by monitor and alerting.
Existing CLI monitor and alerting keep working; they just also update this when present.
"""
import datetime
import threading

_lock = threading.Lock()
# List of {"type", "source", "id", "anomaly_name", "subject", "at"}
alert_history = []
# List of {"source", "id", "name", "rca_text", "at"}
rca_history = []
# {"anomaly": dict, "rca_text": str} or {} (kept for "latest" display)
last_rca = {}
# True while Bedrock RCA is running
rca_loading = False
# Stop requested so monitor loop exits
stop_requested = False
# True while monitor thread is running
monitoring_active = False


def record_alert(alert_type, anomaly, subject, body=""):
    with _lock:
        name = anomaly.get("name") or anomaly.get("report_name") or "?"
        alert_history.append({
            "type": alert_type,
            "source": anomaly.get("source", "?"),
            "id": anomaly.get("id"),
            "anomaly_name": name,
            "subject": (subject or "")[:100],
            "body": body or "",
            "timestamp": datetime.datetime.now().strftime("%H:%M:%S"),
            "at": datetime.datetime.now().isoformat(),
        })


def append_rca(anomaly, rca_text):
    with _lock:
        name = anomaly.get("name") or anomaly.get("report_name") or "?"
        rca_history.append({
            "anomaly": {k: str(v) if not isinstance(v, (str, int, float, type(None))) else v for k, v in anomaly.items()},
            "source": anomaly.get("source", "?"),
            "id": anomaly.get("id"),
            "name": name,
            "rca_text": rca_text or "",
            "at": datetime.datetime.now().isoformat(),
        })


def set_last_rca(anomaly, rca_text):
    global last_rca
    with _lock:
        last_rca = {"anomaly": anomaly, "rca_text": rca_text or ""}


def set_rca_loading(value):
    global rca_loading
    with _lock:
        rca_loading = value


def request_stop():
    global stop_requested
    with _lock:
        stop_requested = True


def clear_stop():
    global stop_requested
    with _lock:
        stop_requested = False


def get_stop_requested():
    with _lock:
        return stop_requested


def set_monitoring_active(value):
    global monitoring_active
    with _lock:
        monitoring_active = value


def clear_session():
    """Clear RCA and alert history so a new monitoring session starts fresh."""
    global alert_history, rca_history, last_rca
    with _lock:
        alert_history.clear()
        rca_history.clear()
        last_rca.clear()


def get_status():
    with _lock:
        return {
            "rca_loading": rca_loading,
            "last_rca": dict(last_rca),
            "rca_history": list(rca_history),
            "alert_history": list(alert_history),
            "monitoring_active": monitoring_active,
        }
