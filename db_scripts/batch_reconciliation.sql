-- batch_reconciliation.sql
-- Simulated long-running batch (full scan, no index)
DECLARE
  v_count NUMBER;
BEGIN
  SELECT COUNT(*)
    INTO v_count
    FROM transactions t
   WHERE t.created_at >= TRUNC(SYSDATE) - 30;
  -- Heavy aggregation without index on created_at
  INSERT INTO reconciliation_summary (batch_date, total_count, updated_at)
  SELECT TRUNC(SYSDATE), COUNT(*), SYSTIMESTAMP
    FROM transactions
   WHERE created_at >= TRUNC(SYSDATE) - 7
   GROUP BY TRUNC(SYSDATE);
  COMMIT;
END;
/
