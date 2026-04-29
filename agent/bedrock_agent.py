import json
import os
import sys

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


def build_user_message(anomaly, diagnostic_text, code_snippets, diagnostic_label="AWR / Diagnostic"):
    parts = [
        "## Anomaly",
        json.dumps(anomaly, default=str, indent=2),
        "",
        "## " + diagnostic_label,
        diagnostic_text,
        "",
        "## Relevant code snippets (PL/SQL from database)",
        code_snippets,
        "",
        "Using the anomaly details, diagnostic (top SQL by elapsed time, execution plans, wait events if present), "
        "and the PL/SQL code above, provide a structured response:",
        "",
        "1. ROOT_CAUSE: One short paragraph. Identify the likely cause (e.g. full table scan, missing index, "
        "correlated subquery, temp space, lock contention). Reference specific SQL_ID or object/line if the "
        "diagnostic or code shows it.",
        "",
        "2. RECOMMENDATIONS: Bullet list of concrete, actionable fixes. Examples: create index on column X, "
        "rewrite query to use exists instead of correlated subquery, increase temp space, "
        "partition table. Be specific to the code and diagnostic given.",
        "",
        "3. CODE_FIX: Provide the corrected PL/SQL or SQL snippet that replaces the faulty code. "
        "Show BEFORE (the problematic section) and AFTER (the fixed version). Keep it short; "
        "show only the changed procedure/query. If no code fix is possible, say 'No code fix applicable'.",
    ]
    return "\n".join(parts)


def invoke_bedrock(user_message, region=None):
    region = region or os.environ.get("AWS_DEFAULT_REGION", "ap-south-1")
    client = boto3.client("bedrock-runtime", region_name=region)
    # Claude 3 Haiku – enable this model in Bedrock console (Mumbai) if needed
    model_id = "anthropic.claude-3-haiku-20240307-v1:0"
    system_prompt = (
        "You are an expert Oracle DBA and performance analyst. "
        "You will receive: (1) an anomaly from BatchLog or ReportLog (long-running or failed batch/report), "
        "(2) a diagnostic section—either live from Oracle V$SQL/V$SQL_PLAN (top SQL, elapsed time, execution plans) "
        "or simulated AWR-style text, and (3) relevant PL/SQL code (packages/procedures) from the database. "
        "Identify the root cause of the slowness or failure and give concrete, actionable recommendations "
        "(e.g. create index, rewrite query, fix logic). Keep the response structured: ROOT_CAUSE paragraph then "
        "RECOMMENDATIONS bullet list. Be concise."
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
    from agent.diagnostics import fetch_diagnostic_report
    from agent.code_crawl import get_code_snippets_for_rca
    diag = fetch_diagnostic_report(anomaly)
    if not diag or "unavailable" in diag or "No SQL rows" in diag:
        diag = read_file("awr_simulated/awr_sample.txt") or diag
        label = "AWR / Diagnostic (fallback simulated)"
    else:
        label = "AWR / Diagnostic (live from V$SQL)"
    code_snippets, _code_label = get_code_snippets_for_rca(anomaly)
    if not (code_snippets or "").strip():
        code_snippets = (
            read_file("db_scripts/batch_reconciliation.sql")
            + "\n\n"
            + read_file("db_scripts/report_regulatory_export.sql")
        )
    user_message = build_user_message(anomaly, diag, code_snippets, label)
    rca_text = invoke_bedrock(user_message)
    return rca_text, diag
