# In-memory set of processed anomaly keys (source, id, type)
# so we don't run RCA twice for the same anomaly.
_processed = set()


def key(anomaly):
    return (anomaly.get("source"), anomaly.get("id"), anomaly.get("type"))


def is_processed(anomaly):
    return key(anomaly) in _processed


def mark_processed(anomaly):
    _processed.add(key(anomaly))
