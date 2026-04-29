-- Phase E updates: Job IDs starting at 1000, cancel/fail support, avg+buffer expected time
-- Run: ./run_sqlcl.sh creditplus/CreditPlus123@localhost:1521/freepdb1 @scripts/phase_e_updates.sql

SET SERVEROUTPUT ON;

-- 1) Add columns to BatchLog / ReportLog (if missing)
BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE BatchLog ADD (job_id NUMBER)';
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE != -01430 THEN RAISE; END IF;
END;
/
BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE ReportLog ADD (job_id NUMBER)';
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE != -01430 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE BatchLog ADD (avg_duration_mins NUMBER)';
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE != -01430 THEN RAISE; END IF;
END;
/
BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE ReportLog ADD (avg_duration_mins NUMBER)';
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE != -01430 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE BatchLog ADD (cancel_requested NUMBER DEFAULT 0)';
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE != -01430 THEN RAISE; END IF;
END;
/
BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE ReportLog ADD (cancel_requested NUMBER DEFAULT 0)';
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE != -01430 THEN RAISE; END IF;
END;
/

BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE BatchLog ADD (cancel_reason VARCHAR2(4000))';
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE != -01430 THEN RAISE; END IF;
END;
/
BEGIN
  EXECUTE IMMEDIATE 'ALTER TABLE ReportLog ADD (cancel_reason VARCHAR2(4000))';
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE != -01430 THEN RAISE; END IF;
END;
/

-- 2) Create sequences for job_id starting at 1000 (drop if exists)
BEGIN EXECUTE IMMEDIATE 'DROP SEQUENCE BATCH_JOB_ID_SEQ'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
BEGIN EXECUTE IMMEDIATE 'DROP SEQUENCE REPORT_JOB_ID_SEQ'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
CREATE SEQUENCE BATCH_JOB_ID_SEQ START WITH 1000 INCREMENT BY 1 NOCACHE;
CREATE SEQUENCE REPORT_JOB_ID_SEQ START WITH 1000 INCREMENT BY 1 NOCACHE;

-- 3) Update PL/SQL packages to support cancel checks (cooperative)
--    We pass job_id into procedures so they can check BatchLog/ReportLog.cancel_requested.

CREATE OR REPLACE PACKAGE PKG_RECONCILIATION AS
  PROCEDURE RUN_RECONCILIATION(p_job_id NUMBER);
END PKG_RECONCILIATION;
/

CREATE OR REPLACE PACKAGE BODY PKG_RECONCILIATION AS
  FUNCTION is_cancelled(p_job_id NUMBER) RETURN BOOLEAN IS
    v_cancel NUMBER;
  BEGIN
    SELECT NVL(cancel_requested,0) INTO v_cancel FROM BatchLog WHERE job_id = p_job_id;
    RETURN v_cancel = 1;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN RETURN FALSE;
  END;

  PROCEDURE RUN_RECONCILIATION(p_job_id NUMBER) IS
    v_mismatches NUMBER;
    v_dupes      NUMBER;
  BEGIN
    -- Simulate long processing with periodic cancel checks (demo-friendly)
    FOR i IN 1..120 LOOP
      IF is_cancelled(p_job_id) THEN
        RETURN;
      END IF;
      DBMS_LOCK.SLEEP(1);
    END LOOP;

    IF is_cancelled(p_job_id) THEN
      RETURN;
    END IF;

    DELETE FROM RECONCILIATION_SUMMARY WHERE batch_date = TRUNC(SYSDATE);

    INSERT INTO RECONCILIATION_SUMMARY (batch_date, merchant_id, total_count, total_amount, updated_at)
    SELECT TRUNC(SYSDATE), t.merchant_id, COUNT(*), SUM(t.amount), SYSTIMESTAMP
    FROM TRANSACTIONS t
    WHERE t.created_at >= SYSTIMESTAMP - INTERVAL '30' DAY
    GROUP BY t.merchant_id;

    IF is_cancelled(p_job_id) THEN
      ROLLBACK;
      RETURN;
    END IF;

    SELECT COUNT(*) INTO v_mismatches
    FROM TRANSACTIONS t1
    WHERE t1.created_at >= SYSTIMESTAMP - INTERVAL '30' DAY
      AND t1.amount > (
        SELECT /*+ NO_UNNEST FULL(t2) */ AVG(t2.amount) * 1.5
        FROM TRANSACTIONS t2
        WHERE t2.merchant_id = t1.merchant_id
          AND t2.created_at >= SYSTIMESTAMP - INTERVAL '30' DAY
      );

    IF is_cancelled(p_job_id) THEN
      ROLLBACK;
      RETURN;
    END IF;

    SELECT COUNT(*) INTO v_dupes
    FROM TRANSACTIONS a
    WHERE a.created_at >= SYSTIMESTAMP - INTERVAL '30' DAY
      AND EXISTS (
        SELECT /*+ NO_UNNEST FULL(b) */ 1
        FROM TRANSACTIONS b
        WHERE b.merchant_id = a.merchant_id
          AND b.amount = a.amount
          AND b.txn_date = a.txn_date
          AND b.txn_id != a.txn_id
          AND b.created_at >= SYSTIMESTAMP - INTERVAL '30' DAY
      );

    COMMIT;
  END RUN_RECONCILIATION;
END PKG_RECONCILIATION;
/


CREATE OR REPLACE PACKAGE PKG_REGULATORY_EXPORT AS
  PROCEDURE RUN_EXPORT(p_job_id NUMBER);
END PKG_REGULATORY_EXPORT;
/

CREATE OR REPLACE PACKAGE BODY PKG_REGULATORY_EXPORT AS
  FUNCTION is_cancelled(p_job_id NUMBER) RETURN BOOLEAN IS
    v_cancel NUMBER;
  BEGIN
    SELECT NVL(cancel_requested,0) INTO v_cancel FROM ReportLog WHERE job_id = p_job_id;
    RETURN v_cancel = 1;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN RETURN FALSE;
  END;

  PROCEDURE RUN_EXPORT(p_job_id NUMBER) IS
    v_count   NUMBER;
    v_invalid NUMBER;
  BEGIN
    -- Short processing with cancel checks
    FOR i IN 1..15 LOOP
      IF is_cancelled(p_job_id) THEN
        RETURN;
      END IF;
      DBMS_LOCK.SLEEP(1);
    END LOOP;

    DELETE FROM EXPORT_STAGING;

    INSERT INTO EXPORT_STAGING (merchant_id, txn_date, amount, exported_at)
    SELECT merchant_id, txn_date, amount, SYSDATE
    FROM TRANSACTIONS
    WHERE created_at >= ADD_MONTHS(SYSTIMESTAMP, -12);

    SELECT COUNT(*) INTO v_count FROM EXPORT_STAGING;

    SELECT COUNT(*) INTO v_invalid
    FROM EXPORT_STAGING
    WHERE amount > 40000;

    IF v_invalid > 0 THEN
      RAISE_APPLICATION_ERROR(-20001,
        'Export validation failed: ' || v_invalid ||
        ' transactions exceed regulatory limit of 40000. Total exported: ' || v_count ||
        '. Manual review required before regulatory submission.');
    END IF;

    COMMIT;
  END RUN_EXPORT;
END PKG_REGULATORY_EXPORT;
/


-- 4) Update PKG_JOB_RUNNER: start returns job_id (>=1000), finish/cancel operates by job_id
CREATE OR REPLACE PACKAGE PKG_JOB_RUNNER AS
  FUNCTION  START_BATCH(p_name VARCHAR2, p_avg_mins NUMBER, p_expected_mins NUMBER) RETURN NUMBER;
  PROCEDURE FINISH_BATCH(p_job_id NUMBER, p_status VARCHAR2, p_error VARCHAR2 DEFAULT NULL);
  PROCEDURE REQUEST_CANCEL_BATCH(p_job_id NUMBER, p_reason VARCHAR2);
  PROCEDURE EXEC_AND_FINISH_BATCH(p_batch_name VARCHAR2, p_job_id NUMBER);

  FUNCTION  START_REPORT(p_name VARCHAR2, p_avg_mins NUMBER, p_expected_mins NUMBER) RETURN NUMBER;
  PROCEDURE FINISH_REPORT(p_job_id NUMBER, p_status VARCHAR2, p_error VARCHAR2 DEFAULT NULL);
  PROCEDURE REQUEST_CANCEL_REPORT(p_job_id NUMBER, p_reason VARCHAR2);
  PROCEDURE EXEC_AND_FINISH_REPORT(p_report_name VARCHAR2, p_job_id NUMBER);
END PKG_JOB_RUNNER;
/

CREATE OR REPLACE PACKAGE BODY PKG_JOB_RUNNER AS

  FUNCTION START_BATCH(p_name VARCHAR2, p_avg_mins NUMBER, p_expected_mins NUMBER) RETURN NUMBER IS
    PRAGMA AUTONOMOUS_TRANSACTION;
    v_job_id NUMBER;
  BEGIN
    v_job_id := BATCH_JOB_ID_SEQ.NEXTVAL;
    INSERT INTO BatchLog (job_id, batch_name, status, start_ts, expected_duration_mins, avg_duration_mins, cancel_requested)
    VALUES (v_job_id, p_name, 'RUNNING', SYSTIMESTAMP, p_expected_mins, p_avg_mins, 0);
    COMMIT;
    RETURN v_job_id;
  END START_BATCH;

  PROCEDURE FINISH_BATCH(p_job_id NUMBER, p_status VARCHAR2, p_error VARCHAR2 DEFAULT NULL) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    UPDATE BatchLog
    SET status = p_status, end_ts = SYSTIMESTAMP, error_message = p_error
    WHERE job_id = p_job_id;
    COMMIT;
  END FINISH_BATCH;

  PROCEDURE REQUEST_CANCEL_BATCH(p_job_id NUMBER, p_reason VARCHAR2) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    UPDATE BatchLog
    SET cancel_requested = 1,
        cancel_reason = p_reason,
        status = 'FAILED',
        end_ts = SYSTIMESTAMP,
        error_message = NVL(error_message, 'Cancelled') || ' | ' || p_reason
    WHERE job_id = p_job_id AND status = 'RUNNING';
    COMMIT;
  END REQUEST_CANCEL_BATCH;

  PROCEDURE EXEC_AND_FINISH_BATCH(p_batch_name VARCHAR2, p_job_id NUMBER) IS
  BEGIN
    CASE p_batch_name
      WHEN 'RECONCILIATION_BATCH' THEN PKG_RECONCILIATION.RUN_RECONCILIATION(p_job_id);
      WHEN 'DAILY_SETTLEMENT'     THEN PKG_SETTLEMENT.RUN_DAILY_SETTLEMENT;
      ELSE RAISE_APPLICATION_ERROR(-20099, 'Unknown batch: ' || p_batch_name);
    END CASE;

    -- If it was cancelled during execution, it is already marked FAILED.
    DECLARE v_status VARCHAR2(32); BEGIN
      SELECT status INTO v_status FROM BatchLog WHERE job_id = p_job_id;
      IF v_status = 'RUNNING' THEN
        FINISH_BATCH(p_job_id, 'COMPLETED');
      END IF;
    END;
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      FINISH_BATCH(p_job_id, 'FAILED', SQLERRM);
  END EXEC_AND_FINISH_BATCH;

  FUNCTION START_REPORT(p_name VARCHAR2, p_avg_mins NUMBER, p_expected_mins NUMBER) RETURN NUMBER IS
    PRAGMA AUTONOMOUS_TRANSACTION;
    v_job_id NUMBER;
  BEGIN
    v_job_id := REPORT_JOB_ID_SEQ.NEXTVAL;
    INSERT INTO ReportLog (job_id, report_name, status, start_ts, expected_duration_mins, avg_duration_mins, cancel_requested)
    VALUES (v_job_id, p_name, 'RUNNING', SYSTIMESTAMP, p_expected_mins, p_avg_mins, 0);
    COMMIT;
    RETURN v_job_id;
  END START_REPORT;

  PROCEDURE FINISH_REPORT(p_job_id NUMBER, p_status VARCHAR2, p_error VARCHAR2 DEFAULT NULL) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    UPDATE ReportLog
    SET status = p_status, end_ts = SYSTIMESTAMP, error_message = p_error
    WHERE job_id = p_job_id;
    COMMIT;
  END FINISH_REPORT;

  PROCEDURE REQUEST_CANCEL_REPORT(p_job_id NUMBER, p_reason VARCHAR2) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    UPDATE ReportLog
    SET cancel_requested = 1,
        cancel_reason = p_reason,
        status = 'FAILED',
        end_ts = SYSTIMESTAMP,
        error_message = NVL(error_message, 'Cancelled') || ' | ' || p_reason
    WHERE job_id = p_job_id AND status = 'RUNNING';
    COMMIT;
  END REQUEST_CANCEL_REPORT;

  PROCEDURE EXEC_AND_FINISH_REPORT(p_report_name VARCHAR2, p_job_id NUMBER) IS
  BEGIN
    CASE p_report_name
      WHEN 'REGULATORY_EXPORT' THEN PKG_REGULATORY_EXPORT.RUN_EXPORT(p_job_id);
      WHEN 'TXN_SYNC'          THEN PKG_TXN_SYNC.RUN_TXN_SYNC;
      ELSE RAISE_APPLICATION_ERROR(-20099, 'Unknown report: ' || p_report_name);
    END CASE;

    DECLARE v_status VARCHAR2(32); BEGIN
      SELECT status INTO v_status FROM ReportLog WHERE job_id = p_job_id;
      IF v_status = 'RUNNING' THEN
        FINISH_REPORT(p_job_id, 'COMPLETED');
      END IF;
    END;
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      FINISH_REPORT(p_job_id, 'FAILED', SQLERRM);
  END EXEC_AND_FINISH_REPORT;

END PKG_JOB_RUNNER;
/


PROMPT Phase E updates applied.
SELECT object_name, object_type, status FROM USER_OBJECTS
WHERE object_type IN ('PACKAGE', 'PACKAGE BODY')
  AND object_name IN ('PKG_JOB_RUNNER','PKG_RECONCILIATION','PKG_REGULATORY_EXPORT')
ORDER BY object_name, object_type;

EXIT;

