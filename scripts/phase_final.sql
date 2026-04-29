-- Final phase: seconds-based timing, new batches/reports, cancel support
-- Run: ./run_sqlcl.sh creditplus/CreditPlus123@localhost:1521/freepdb1 @scripts/phase_final.sql
SET SERVEROUTPUT ON;

-- ============================================
-- 1. CONVERT COLUMNS: mins → secs
-- ============================================
BEGIN EXECUTE IMMEDIATE 'ALTER TABLE BatchLog ADD (expected_duration_secs NUMBER)'; EXCEPTION WHEN OTHERS THEN IF SQLCODE != -01430 THEN RAISE; END IF; END;
/
BEGIN EXECUTE IMMEDIATE 'ALTER TABLE BatchLog ADD (avg_duration_secs NUMBER)'; EXCEPTION WHEN OTHERS THEN IF SQLCODE != -01430 THEN RAISE; END IF; END;
/
BEGIN EXECUTE IMMEDIATE 'ALTER TABLE ReportLog ADD (expected_duration_secs NUMBER)'; EXCEPTION WHEN OTHERS THEN IF SQLCODE != -01430 THEN RAISE; END IF; END;
/
BEGIN EXECUTE IMMEDIATE 'ALTER TABLE ReportLog ADD (avg_duration_secs NUMBER)'; EXCEPTION WHEN OTHERS THEN IF SQLCODE != -01430 THEN RAISE; END IF; END;
/

-- Ensure job_id, cancel columns exist
BEGIN EXECUTE IMMEDIATE 'ALTER TABLE BatchLog ADD (job_id NUMBER)'; EXCEPTION WHEN OTHERS THEN IF SQLCODE != -01430 THEN RAISE; END IF; END;
/
BEGIN EXECUTE IMMEDIATE 'ALTER TABLE ReportLog ADD (job_id NUMBER)'; EXCEPTION WHEN OTHERS THEN IF SQLCODE != -01430 THEN RAISE; END IF; END;
/
BEGIN EXECUTE IMMEDIATE 'ALTER TABLE BatchLog ADD (cancel_requested NUMBER DEFAULT 0)'; EXCEPTION WHEN OTHERS THEN IF SQLCODE != -01430 THEN RAISE; END IF; END;
/
BEGIN EXECUTE IMMEDIATE 'ALTER TABLE ReportLog ADD (cancel_requested NUMBER DEFAULT 0)'; EXCEPTION WHEN OTHERS THEN IF SQLCODE != -01430 THEN RAISE; END IF; END;
/
BEGIN EXECUTE IMMEDIATE 'ALTER TABLE BatchLog ADD (cancel_reason VARCHAR2(4000))'; EXCEPTION WHEN OTHERS THEN IF SQLCODE != -01430 THEN RAISE; END IF; END;
/
BEGIN EXECUTE IMMEDIATE 'ALTER TABLE ReportLog ADD (cancel_reason VARCHAR2(4000))'; EXCEPTION WHEN OTHERS THEN IF SQLCODE != -01430 THEN RAISE; END IF; END;
/
BEGIN EXECUTE IMMEDIATE 'ALTER TABLE BatchLog ADD (avg_duration_mins NUMBER)'; EXCEPTION WHEN OTHERS THEN IF SQLCODE != -01430 THEN RAISE; END IF; END;
/
BEGIN EXECUTE IMMEDIATE 'ALTER TABLE ReportLog ADD (avg_duration_mins NUMBER)'; EXCEPTION WHEN OTHERS THEN IF SQLCODE != -01430 THEN RAISE; END IF; END;
/

PROMPT [1] Schema columns ready

-- ============================================
-- 2. SEQUENCES (job_id starting 1000)
-- ============================================
BEGIN EXECUTE IMMEDIATE 'DROP SEQUENCE BATCH_JOB_ID_SEQ'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
BEGIN EXECUTE IMMEDIATE 'DROP SEQUENCE REPORT_JOB_ID_SEQ'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
CREATE SEQUENCE BATCH_JOB_ID_SEQ START WITH 1000 INCREMENT BY 1 NOCACHE;
CREATE SEQUENCE REPORT_JOB_ID_SEQ START WITH 1000 INCREMENT BY 1 NOCACHE;

PROMPT [2] Sequences created (start 1000)

-- ============================================
-- 3. ADDITIONAL TABLES for new batches
-- ============================================
BEGIN EXECUTE IMMEDIATE 'CREATE TABLE FRAUD_ALERTS (
    id NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    merchant_id VARCHAR2(32),
    txn_id NUMBER,
    alert_type VARCHAR2(64),
    created_at TIMESTAMP DEFAULT SYSTIMESTAMP
)'; EXCEPTION WHEN OTHERS THEN NULL; END;
/

BEGIN EXECUTE IMMEDIATE 'CREATE TABLE EOD_BALANCES (
    id NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    balance_date DATE,
    merchant_id VARCHAR2(32),
    closing_balance NUMBER(18,2),
    created_at TIMESTAMP DEFAULT SYSTIMESTAMP
)'; EXCEPTION WHEN OTHERS THEN NULL; END;
/

BEGIN EXECUTE IMMEDIATE 'CREATE TABLE MERCHANT_REPORT_DATA (
    id NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    merchant_id VARCHAR2(32),
    report_month DATE,
    txn_count NUMBER,
    total_amount NUMBER(18,2),
    created_at TIMESTAMP DEFAULT SYSTIMESTAMP
)'; EXCEPTION WHEN OTHERS THEN NULL; END;
/

PROMPT [3] Additional tables ready

-- ============================================
-- 4. NEW PL/SQL PACKAGES
-- ============================================

-- 4a. PKG_FRAUD_CHECK (SLOW + FAULTY: cartesian-like join, no proper filter)
CREATE OR REPLACE PACKAGE PKG_FRAUD_CHECK AS
    PROCEDURE RUN_FRAUD_CHECK(p_job_id NUMBER);
END PKG_FRAUD_CHECK;
/

CREATE OR REPLACE PACKAGE BODY PKG_FRAUD_CHECK AS
    FUNCTION is_cancelled(p_job_id NUMBER) RETURN BOOLEAN IS
        v_cancel NUMBER;
    BEGIN
        SELECT NVL(cancel_requested,0) INTO v_cancel FROM BatchLog WHERE job_id = p_job_id;
        RETURN v_cancel = 1;
    EXCEPTION WHEN NO_DATA_FOUND THEN RETURN FALSE;
    END;

    PROCEDURE RUN_FRAUD_CHECK(p_job_id NUMBER) IS
        v_count NUMBER;
    BEGIN
        DELETE FROM FRAUD_ALERTS;

        -- BUG: Missing join condition causes near-cartesian product (very slow)
        INSERT INTO FRAUD_ALERTS (merchant_id, txn_id, alert_type)
        SELECT /*+ NO_MERGE FULL(t1) FULL(t2) */ t1.merchant_id, t1.txn_id, 'DUPLICATE_AMOUNT'
        FROM TRANSACTIONS t1, TRANSACTIONS t2
        WHERE t1.amount = t2.amount
          AND t1.txn_id != t2.txn_id
          AND t1.txn_date >= TRUNC(SYSDATE) - 7
          AND ROWNUM <= 500;

        FOR i IN 1..70 LOOP
            IF is_cancelled(p_job_id) THEN RETURN; END IF;
            DBMS_SESSION.SLEEP(1);
        END LOOP;

        SELECT COUNT(*) INTO v_count FROM FRAUD_ALERTS;
        IF v_count > 200 THEN
            RAISE_APPLICATION_ERROR(-20002, 'Fraud check: too many alerts (' || v_count || '). Possible cartesian join issue.');
        END IF;

        COMMIT;
    END RUN_FRAUD_CHECK;
END PKG_FRAUD_CHECK;
/

PROMPT [4a] PKG_FRAUD_CHECK created (FAULTY: cartesian join)


-- 4b. PKG_EOD_BALANCE (FAST: simple aggregation on indexed column)
CREATE OR REPLACE PACKAGE PKG_EOD_BALANCE AS
    PROCEDURE RUN_EOD_BALANCE;
END PKG_EOD_BALANCE;
/

CREATE OR REPLACE PACKAGE BODY PKG_EOD_BALANCE AS
    PROCEDURE RUN_EOD_BALANCE IS
    BEGIN
        DELETE FROM EOD_BALANCES WHERE balance_date = TRUNC(SYSDATE);

        INSERT INTO EOD_BALANCES (balance_date, merchant_id, closing_balance)
        SELECT TRUNC(SYSDATE), merchant_id, SUM(CASE WHEN txn_type='REFUND' THEN -amount ELSE amount END)
        FROM TRANSACTIONS
        WHERE txn_date = TRUNC(SYSDATE) AND status = 'SUCCESS'
        GROUP BY merchant_id;

        COMMIT;
    END RUN_EOD_BALANCE;
END PKG_EOD_BALANCE;
/

PROMPT [4b] PKG_EOD_BALANCE created (fast)


-- 4c. PKG_MERCHANT_REPORT (SLOW: full scan on created_at without index)
CREATE OR REPLACE PACKAGE PKG_MERCHANT_REPORT AS
    PROCEDURE RUN_MERCHANT_REPORT(p_job_id NUMBER);
END PKG_MERCHANT_REPORT;
/

CREATE OR REPLACE PACKAGE BODY PKG_MERCHANT_REPORT AS
    FUNCTION is_cancelled(p_job_id NUMBER) RETURN BOOLEAN IS
        v_cancel NUMBER;
    BEGIN
        SELECT NVL(cancel_requested,0) INTO v_cancel FROM ReportLog WHERE job_id = p_job_id;
        RETURN v_cancel = 1;
    EXCEPTION WHEN NO_DATA_FOUND THEN RETURN FALSE;
    END;

    PROCEDURE RUN_MERCHANT_REPORT(p_job_id NUMBER) IS
        v_count NUMBER;
    BEGIN
        DELETE FROM MERCHANT_REPORT_DATA;

        -- BUG: Scanning created_at (no index) + correlated subquery
        INSERT INTO MERCHANT_REPORT_DATA (merchant_id, report_month, txn_count, total_amount)
        SELECT t.merchant_id, TRUNC(SYSDATE, 'MM'), COUNT(*), SUM(t.amount)
        FROM TRANSACTIONS t
        WHERE t.created_at >= SYSTIMESTAMP - INTERVAL '90' DAY
          AND t.amount > (
              SELECT /*+ NO_UNNEST FULL(t2) */ AVG(t2.amount)
              FROM TRANSACTIONS t2
              WHERE t2.merchant_id = t.merchant_id
                AND t2.created_at >= SYSTIMESTAMP - INTERVAL '90' DAY
          )
        GROUP BY t.merchant_id;

        FOR i IN 1..55 LOOP
            IF is_cancelled(p_job_id) THEN RETURN; END IF;
            DBMS_SESSION.SLEEP(1);
        END LOOP;

        COMMIT;
    END RUN_MERCHANT_REPORT;
END PKG_MERCHANT_REPORT;
/

PROMPT [4c] PKG_MERCHANT_REPORT created (FAULTY: no index on created_at + correlated subquery)


-- 4d. PKG_DAILY_SUMMARY (FAST: simple indexed query)
CREATE OR REPLACE PACKAGE PKG_DAILY_SUMMARY AS
    PROCEDURE RUN_DAILY_SUMMARY;
END PKG_DAILY_SUMMARY;
/

CREATE OR REPLACE PACKAGE BODY PKG_DAILY_SUMMARY AS
    PROCEDURE RUN_DAILY_SUMMARY IS
        v_count NUMBER;
        v_total NUMBER;
    BEGIN
        SELECT COUNT(*), NVL(SUM(amount),0)
        INTO v_count, v_total
        FROM TRANSACTIONS
        WHERE txn_date = TRUNC(SYSDATE);

        DBMS_OUTPUT.PUT_LINE('Daily summary: ' || v_count || ' txns, total ' || v_total);
    END RUN_DAILY_SUMMARY;
END PKG_DAILY_SUMMARY;
/

PROMPT [4d] PKG_DAILY_SUMMARY created (fast)


-- ============================================
-- 5. UPDATE EXISTING PACKAGES for cancel + job_id
-- ============================================

-- 5a. PKG_RECONCILIATION (already updated in phase_e if run; re-create to be safe)
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
    EXCEPTION WHEN NO_DATA_FOUND THEN RETURN FALSE;
    END;

    PROCEDURE RUN_RECONCILIATION(p_job_id NUMBER) IS
        v_mismatches NUMBER;
        v_dupes      NUMBER;
    BEGIN
        FOR i IN 1..120 LOOP
            IF is_cancelled(p_job_id) THEN RETURN; END IF;
            DBMS_SESSION.SLEEP(1);
        END LOOP;

        DELETE FROM RECONCILIATION_SUMMARY WHERE batch_date = TRUNC(SYSDATE);

        INSERT INTO RECONCILIATION_SUMMARY (batch_date, merchant_id, total_count, total_amount, updated_at)
        SELECT TRUNC(SYSDATE), t.merchant_id, COUNT(*), SUM(t.amount), SYSTIMESTAMP
        FROM TRANSACTIONS t
        WHERE t.created_at >= SYSTIMESTAMP - INTERVAL '30' DAY
        GROUP BY t.merchant_id;

        IF is_cancelled(p_job_id) THEN ROLLBACK; RETURN; END IF;

        SELECT COUNT(*) INTO v_mismatches
        FROM TRANSACTIONS t1
        WHERE t1.created_at >= SYSTIMESTAMP - INTERVAL '30' DAY
          AND t1.amount > (
              SELECT /*+ NO_UNNEST FULL(t2) */ AVG(t2.amount) * 1.5
              FROM TRANSACTIONS t2
              WHERE t2.merchant_id = t1.merchant_id
                AND t2.created_at >= SYSTIMESTAMP - INTERVAL '30' DAY
          );

        COMMIT;
    END RUN_RECONCILIATION;
END PKG_RECONCILIATION;
/

PROMPT [5a] PKG_RECONCILIATION updated


-- 5b. PKG_REGULATORY_EXPORT
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
    EXCEPTION WHEN NO_DATA_FOUND THEN RETURN FALSE;
    END;

    PROCEDURE RUN_EXPORT(p_job_id NUMBER) IS
        v_count   NUMBER;
        v_invalid NUMBER;
    BEGIN
        FOR i IN 1..15 LOOP
            IF is_cancelled(p_job_id) THEN RETURN; END IF;
            DBMS_SESSION.SLEEP(1);
        END LOOP;

        DELETE FROM EXPORT_STAGING;

        INSERT INTO EXPORT_STAGING (merchant_id, txn_date, amount, exported_at)
        SELECT merchant_id, txn_date, amount, SYSDATE
        FROM TRANSACTIONS
        WHERE created_at >= ADD_MONTHS(SYSTIMESTAMP, -12);

        SELECT COUNT(*) INTO v_count FROM EXPORT_STAGING;
        SELECT COUNT(*) INTO v_invalid FROM EXPORT_STAGING WHERE amount > 40000;

        IF v_invalid > 0 THEN
            RAISE_APPLICATION_ERROR(-20001,
                'Export validation failed: ' || v_invalid ||
                ' transactions exceed regulatory limit of 40000. Total exported: ' || v_count);
        END IF;

        COMMIT;
    END RUN_EXPORT;
END PKG_REGULATORY_EXPORT;
/

PROMPT [5b] PKG_REGULATORY_EXPORT updated


-- ============================================
-- 6. PKG_JOB_RUNNER (seconds-based, all jobs)
-- ============================================

CREATE OR REPLACE PACKAGE PKG_JOB_RUNNER AS
    FUNCTION  START_BATCH(p_name VARCHAR2, p_avg_secs NUMBER, p_expected_secs NUMBER) RETURN NUMBER;
    PROCEDURE FINISH_BATCH(p_job_id NUMBER, p_status VARCHAR2, p_error VARCHAR2 DEFAULT NULL);
    PROCEDURE REQUEST_CANCEL_BATCH(p_job_id NUMBER, p_reason VARCHAR2);
    PROCEDURE EXEC_AND_FINISH_BATCH(p_batch_name VARCHAR2, p_job_id NUMBER);

    FUNCTION  START_REPORT(p_name VARCHAR2, p_avg_secs NUMBER, p_expected_secs NUMBER) RETURN NUMBER;
    PROCEDURE FINISH_REPORT(p_job_id NUMBER, p_status VARCHAR2, p_error VARCHAR2 DEFAULT NULL);
    PROCEDURE REQUEST_CANCEL_REPORT(p_job_id NUMBER, p_reason VARCHAR2);
    PROCEDURE EXEC_AND_FINISH_REPORT(p_report_name VARCHAR2, p_job_id NUMBER);
END PKG_JOB_RUNNER;
/

CREATE OR REPLACE PACKAGE BODY PKG_JOB_RUNNER AS

    FUNCTION START_BATCH(p_name VARCHAR2, p_avg_secs NUMBER, p_expected_secs NUMBER) RETURN NUMBER IS
        PRAGMA AUTONOMOUS_TRANSACTION;
        v_job_id NUMBER;
    BEGIN
        v_job_id := BATCH_JOB_ID_SEQ.NEXTVAL;
        INSERT INTO BatchLog (job_id, batch_name, status, start_ts, expected_duration_secs, avg_duration_secs, cancel_requested)
        VALUES (v_job_id, p_name, 'RUNNING', SYSTIMESTAMP, p_expected_secs, p_avg_secs, 0);
        COMMIT;
        RETURN v_job_id;
    END START_BATCH;

    PROCEDURE FINISH_BATCH(p_job_id NUMBER, p_status VARCHAR2, p_error VARCHAR2 DEFAULT NULL) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        UPDATE BatchLog SET status = p_status, end_ts = SYSTIMESTAMP, error_message = p_error WHERE job_id = p_job_id;
        COMMIT;
    END FINISH_BATCH;

    PROCEDURE REQUEST_CANCEL_BATCH(p_job_id NUMBER, p_reason VARCHAR2) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        UPDATE BatchLog
        SET cancel_requested = 1, cancel_reason = p_reason,
            status = 'FAILED', end_ts = SYSTIMESTAMP,
            error_message = NVL(error_message, 'Cancelled') || ' | ' || p_reason
        WHERE job_id = p_job_id AND status = 'RUNNING';
        COMMIT;
    END REQUEST_CANCEL_BATCH;

    PROCEDURE EXEC_AND_FINISH_BATCH(p_batch_name VARCHAR2, p_job_id NUMBER) IS
    BEGIN
        CASE p_batch_name
            WHEN 'RECONCILIATION_BATCH' THEN PKG_RECONCILIATION.RUN_RECONCILIATION(p_job_id);
            WHEN 'DAILY_SETTLEMENT'     THEN PKG_SETTLEMENT.RUN_DAILY_SETTLEMENT;
            WHEN 'FRAUD_CHECK_BATCH'    THEN PKG_FRAUD_CHECK.RUN_FRAUD_CHECK(p_job_id);
            WHEN 'EOD_BALANCE_BATCH'    THEN PKG_EOD_BALANCE.RUN_EOD_BALANCE;
            ELSE RAISE_APPLICATION_ERROR(-20099, 'Unknown batch: ' || p_batch_name);
        END CASE;
        DECLARE v_status VARCHAR2(32); BEGIN
            SELECT status INTO v_status FROM BatchLog WHERE job_id = p_job_id;
            IF v_status = 'RUNNING' THEN FINISH_BATCH(p_job_id, 'COMPLETED'); END IF;
        END;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            FINISH_BATCH(p_job_id, 'FAILED', SQLERRM);
    END EXEC_AND_FINISH_BATCH;

    FUNCTION START_REPORT(p_name VARCHAR2, p_avg_secs NUMBER, p_expected_secs NUMBER) RETURN NUMBER IS
        PRAGMA AUTONOMOUS_TRANSACTION;
        v_job_id NUMBER;
    BEGIN
        v_job_id := REPORT_JOB_ID_SEQ.NEXTVAL;
        INSERT INTO ReportLog (job_id, report_name, status, start_ts, expected_duration_secs, avg_duration_secs, cancel_requested)
        VALUES (v_job_id, p_name, 'RUNNING', SYSTIMESTAMP, p_expected_secs, p_avg_secs, 0);
        COMMIT;
        RETURN v_job_id;
    END START_REPORT;

    PROCEDURE FINISH_REPORT(p_job_id NUMBER, p_status VARCHAR2, p_error VARCHAR2 DEFAULT NULL) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        UPDATE ReportLog SET status = p_status, end_ts = SYSTIMESTAMP, error_message = p_error WHERE job_id = p_job_id;
        COMMIT;
    END FINISH_REPORT;

    PROCEDURE REQUEST_CANCEL_REPORT(p_job_id NUMBER, p_reason VARCHAR2) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        UPDATE ReportLog
        SET cancel_requested = 1, cancel_reason = p_reason,
            status = 'FAILED', end_ts = SYSTIMESTAMP,
            error_message = NVL(error_message, 'Cancelled') || ' | ' || p_reason
        WHERE job_id = p_job_id AND status = 'RUNNING';
        COMMIT;
    END REQUEST_CANCEL_REPORT;

    PROCEDURE EXEC_AND_FINISH_REPORT(p_report_name VARCHAR2, p_job_id NUMBER) IS
    BEGIN
        CASE p_report_name
            WHEN 'REGULATORY_EXPORT'  THEN PKG_REGULATORY_EXPORT.RUN_EXPORT(p_job_id);
            WHEN 'TXN_SYNC'           THEN PKG_TXN_SYNC.RUN_TXN_SYNC;
            WHEN 'MERCHANT_REPORT'    THEN PKG_MERCHANT_REPORT.RUN_MERCHANT_REPORT(p_job_id);
            WHEN 'DAILY_SUMMARY'      THEN PKG_DAILY_SUMMARY.RUN_DAILY_SUMMARY;
            ELSE RAISE_APPLICATION_ERROR(-20099, 'Unknown report: ' || p_report_name);
        END CASE;
        DECLARE v_status VARCHAR2(32); BEGIN
            SELECT status INTO v_status FROM ReportLog WHERE job_id = p_job_id;
            IF v_status = 'RUNNING' THEN FINISH_REPORT(p_job_id, 'COMPLETED'); END IF;
        END;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            FINISH_REPORT(p_job_id, 'FAILED', SQLERRM);
    END EXEC_AND_FINISH_REPORT;

END PKG_JOB_RUNNER;
/


-- ============================================
-- 7. VERIFY
-- ============================================
SELECT object_name, object_type, status FROM USER_OBJECTS
WHERE object_type IN ('PACKAGE', 'PACKAGE BODY')
ORDER BY object_name, object_type;

PROMPT
PROMPT Phase FINAL setup complete.
PROMPT New faulty batches/reports:
PROMPT   - FRAUD_CHECK_BATCH   (cartesian join, slow ~60s, may fail)
PROMPT   - MERCHANT_REPORT     (no index + correlated subquery, slow ~45s)
PROMPT Normal batches/reports:
PROMPT   - EOD_BALANCE_BATCH   (fast)
PROMPT   - DAILY_SUMMARY       (fast)
PROMPT All times now in SECONDS.

EXIT;
