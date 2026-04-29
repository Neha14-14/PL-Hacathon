-- Patch: make RECONCILIATION, FRAUD_CHECK, MERCHANT_REPORT run longer than expected (avg+10%)
-- so they are detected as long-running by the monitor. Run after phase_final.sql:
--   ./run_sqlcl.sh creditplus/CreditPlus123@localhost:1521/freepdb1 @scripts/patch_long_running.sql

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
              SELECT AVG(t2.amount) * 1.5
              FROM TRANSACTIONS t2
              WHERE t2.merchant_id = t1.merchant_id
                AND t2.created_at >= SYSTIMESTAMP - INTERVAL '30' DAY
          );
        COMMIT;
    END RUN_RECONCILIATION;
END PKG_RECONCILIATION;
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
        INSERT INTO FRAUD_ALERTS (merchant_id, txn_id, alert_type)
        SELECT t1.merchant_id, t1.txn_id, 'DUPLICATE_AMOUNT'
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
            RAISE_APPLICATION_ERROR(-20002, 'Fraud check: too many alerts (' || v_count || ').');
        END IF;
        COMMIT;
    END RUN_FRAUD_CHECK;
END PKG_FRAUD_CHECK;
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
    BEGIN
        DELETE FROM MERCHANT_REPORT_DATA;
        INSERT INTO MERCHANT_REPORT_DATA (merchant_id, report_month, txn_count, total_amount)
        SELECT t.merchant_id, TRUNC(SYSDATE, 'MM'), COUNT(*), SUM(t.amount)
        FROM TRANSACTIONS t
        WHERE t.created_at >= SYSTIMESTAMP - INTERVAL '90' DAY
          AND t.amount > (
              SELECT AVG(t2.amount)
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

PROMPT Patch applied: RECONCILIATION 120s, FRAUD_CHECK 70s, MERCHANT_REPORT 55s (exceed avg+10%%)
EXIT;
