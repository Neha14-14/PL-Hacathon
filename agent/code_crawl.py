"""
Phase C: Code crawling via ALL_SOURCE.
Given SQL_ID(s) from diagnostics, find package/procedure/function that contains
that SQL and return full source for Bedrock RCA.
"""
import re
from agent.db import get_connection
from agent.diagnostics import fetch_sql_text

# Map anomaly batch/report name to (owner, object_name) for fallback when no SQL_ID match.
ANOMALY_TO_OBJECT = {
    "RECONCILIATION_BATCH": ("CREDITPLUS", "PKG_RECONCILIATION"),
    "DAILY_SETTLEMENT":     ("CREDITPLUS", "PKG_SETTLEMENT"),
    "FRAUD_CHECK_BATCH":    ("CREDITPLUS", "PKG_FRAUD_CHECK"),
    "EOD_BALANCE_BATCH":    ("CREDITPLUS", "PKG_EOD_BALANCE"),
    "REGULATORY_EXPORT":    ("CREDITPLUS", "PKG_REGULATORY_EXPORT"),
    "TXN_SYNC":             ("CREDITPLUS", "PKG_TXN_SYNC"),
    "MERCHANT_REPORT":      ("CREDITPLUS", "PKG_MERCHANT_REPORT"),
    "DAILY_SUMMARY":        ("CREDITPLUS", "PKG_DAILY_SUMMARY"),
}


def _normalize_fragment(sql_text, max_len=100):
    """Normalize SQL for search: single line, collapsed spaces, safe length."""
    if not sql_text or not sql_text.strip():
        return ""
    one_line = re.sub(r"\s+", " ", sql_text.strip())
    return one_line[:max_len].strip()


def find_objects_containing_sql(conn, sql_text):
    """
    Search ALL_SOURCE for objects whose source contains the given SQL fragment.
    Returns list of (owner, name, type).
    """
    frag = _normalize_fragment(sql_text, 100)
    if not frag:
        return []
    cur = conn.cursor()
    try:
        # INSTR avoids LIKE so no need to escape % or _ in fragment
        cur.execute("""
            SELECT DISTINCT OWNER, NAME, TYPE
            FROM ALL_SOURCE
            WHERE INSTR(UPPER(TEXT), UPPER(:frag)) > 0
              AND TYPE IN ('PACKAGE BODY', 'PROCEDURE', 'FUNCTION', 'PACKAGE')
            ORDER BY OWNER, NAME, TYPE
        """, frag=frag)
        return cur.fetchall()
    except Exception:
        return []


def get_source_for_object(conn, owner, name, obj_type):
    """Return full source code for the given object from ALL_SOURCE."""
    cur = conn.cursor()
    try:
        cur.execute("""
            SELECT LINE, TEXT
            FROM ALL_SOURCE
            WHERE OWNER = :owner AND NAME = :name AND TYPE = :typ
            ORDER BY LINE
        """, owner=owner, name=name, typ=obj_type)
        rows = cur.fetchall()
        return "".join(r[1] for r in rows) if rows else ""
    except Exception:
        return ""


def crawl_code_for_sql_ids(anomaly, sql_ids):
    """
    For each SQL_ID, get SQL text from V$SQLTEXT, find objects in ALL_SOURCE that
    contain it, and return concatenated source (deduped by owner.name).
    Returns (code_text, label). Label indicates "from ALL_SOURCE (SQL_ID)" or fallback.
    """
    if not sql_ids:
        return _fallback_code_for_anomaly(anomaly), "Relevant code (fallback by anomaly name)"

    conn = get_connection()
    seen = set()
    parts = []
    try:
        for sql_id in sql_ids[:5]:
            sql_text = fetch_sql_text(conn, sql_id)
            if not sql_text:
                continue
            objs = find_objects_containing_sql(conn, sql_text)
            for row in objs:
                owner, name, typ = row[0], row[1], row[2]
                key = (owner, name, typ)
                if key in seen:
                    continue
                seen.add(key)
                src = get_source_for_object(conn, owner, name, typ)
                if src:
                    parts.append("--- {} {}.{} ({}) ---\n{}".format(typ, owner, name, sql_id, src))
        conn.close()
    except Exception:
        if conn:
            try:
                conn.close()
            except Exception:
                pass
        return _fallback_code_for_anomaly(anomaly), "Relevant code (fallback)"

    if parts:
        return "\n\n".join(parts), "Relevant code (from ALL_SOURCE by SQL_ID)"
    return _fallback_code_for_anomaly(anomaly), "Relevant code (fallback by anomaly name)"


def _fallback_code_for_anomaly(anomaly):
    """Get source from ALL_SOURCE by mapping anomaly name to package name."""
    name = (anomaly.get("name") or anomaly.get("report_name") or "").strip().upper()
    if not name:
        return ""
    t = ANOMALY_TO_OBJECT.get(name)
    if not t:
        return ""
    owner, obj_name = t
    conn = get_connection()
    try:
        # Prefer PACKAGE BODY (has implementation), else PACKAGE (spec)
        for typ in ("PACKAGE BODY", "PACKAGE"):
            src = get_source_for_object(conn, owner, obj_name, typ)
            if src:
                conn.close()
                return "--- {} {}.{} (fallback by name) ---\n{}".format(typ, owner, obj_name, src)
        conn.close()
    except Exception:
        try:
            conn.close()
        except Exception:
            pass
    return ""


def get_code_snippets_for_rca(anomaly):
    """
    Public API: return (code_text, label) for use in RCA.
    Tries SQL_ID-based crawl first (if diagnostics returns SQL_IDs), else fallback by anomaly name.
    """
    from agent.diagnostics import get_top_sql_ids
    sql_ids = get_top_sql_ids(anomaly, top_n=5)
    return crawl_code_for_sql_ids(anomaly, sql_ids)
