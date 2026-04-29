import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from agent.aws_env import load_aws_env
load_aws_env()

import boto3


def load_paths():
    base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    with open(os.path.join(base, "config", "paths.json")) as f:
        return json.load(f)


def send_immediate_alert(anomaly):
    """Alert 1: sent as soon as an anomaly is detected (before RCA)."""
    subject = "[CreditPlus] Anomaly: {} - {} (id={})".format(
        anomaly.get("type", ""),
        anomaly.get("name", anomaly.get("report_name", "?")),
        anomaly.get("id"),
    )
    body = "Anomaly detected:\n\n" + json.dumps(anomaly, default=str, indent=2)
    _publish(subject, body)
    _write_local("immediate", subject, body)
    try:
        from agent.state import record_alert
        record_alert("immediate", anomaly, subject, body)
    except Exception:
        pass


def send_rca_alert(anomaly, awr_snippet, rca_text):
    """Alert 2: sent after RCA with AWR snippet + root cause + recommendations."""
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
    try:
        from agent.state import record_alert
        record_alert("rca", anomaly, subject, body)
    except Exception:
        pass


def _publish(subject, body):
    paths = load_paths()
    arn = paths.get("sns_topic_arn")
    if not arn:
        print("  (SNS not configured; alert saved locally only)")
        return
    try:
        region = os.environ.get("AWS_DEFAULT_REGION", "ap-south-1")
        boto3.client("sns", region_name=region).publish(
            TopicArn=arn, Subject=subject[:100], Message=body
        )
        print("  [SNS] Alert sent:", subject[:80])
    except Exception as e:
        print("  [SNS ERROR]", e)


def _write_local(kind, subject, body):
    paths = load_paths()
    alerts_dir = paths.get("alerts_dir", "alerts")
    base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out_dir = os.path.join(base, alerts_dir)
    os.makedirs(out_dir, exist_ok=True)
    fname = os.path.join(out_dir, "{}_{}.txt".format(kind, int(time.time())))
    with open(fname, "w") as f:
        f.write(subject + "\n\n" + body)
    print("  [LOCAL] Alert saved:", fname)
