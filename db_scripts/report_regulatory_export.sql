-- report_regulatory_export.sql
-- Export to temp; may hit ORA-01652 if temp too small
CREATE GLOBAL TEMPORARY TABLE export_work (
  id NUMBER,
  merchant_id VARCHAR2(32),
  txn_date DATE,
  amount NUMBER(18,2)
) ON COMMIT PRESERVE ROWS;

INSERT INTO export_work (id, merchant_id, txn_date, amount)
SELECT ROWNUM, merchant_id, txn_date, amount
  FROM transactions
 WHERE txn_date >= ADD_MONTHS(TRUNC(SYSDATE), -12);
-- Large result set can exhaust temp tablespace
