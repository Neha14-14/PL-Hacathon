-- Phase A: Real data tables, bulk data, PL/SQL packages, job runner
-- Run: ./run_sqlcl.sh creditplus/CreditPlus123@localhost:1521/freepdb1 @scripts/phase_a_setup.sql

SET SERVEROUTPUT ON;

-- ============================================
-- 1. DROP EXISTING OBJECTS (safe)
-- ============================================
BEGIN EXECUTE IMMEDIATE 'DROP TABLE EXPORT_STAGING CASCADE CONSTRAINTS PURGE'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
BEGIN EXECUTE IMMEDIATE 'DROP TABLE SETTLEMENT_LEDGER CASCADE CONSTRAINTS PURGE'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
BEGIN EXECUTE IMMEDIATE 'DROP TABLE RECONCILIATION_SUMMARY CASCADE CONSTRAINTS PURGE'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
BEGIN EXECUTE IMMEDIATE 'DROP TABLE TRANSACTIONS CASCADE CONSTRAINTS PURGE'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
BEGIN EXECUTE IMMEDIATE 'DROP TABLE MERCHANTS CASCADE CONSTRAINTS PURGE'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
BEGIN EXECUTE IMMEDIATE 'DROP PACKAGE PKG_JOB_RUNNER'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
BEGIN EXECUTE IMMEDIATE 'DROP PACKAGE PKG_RECONCILIATION'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
BEGIN EXECUTE IMMEDIATE 'DROP PACKAGE PKG_REGULATORY_EXPORT'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
BEGIN EXECUTE IMMEDIATE 'DROP PACKAGE PKG_SETTLEMENT'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
BEGIN EXECUTE IMMEDIATE 'DROP PACKAGE PKG_TXN_SYNC'; EXCEPTION WHEN OTHERS THEN NULL; END;
/

PROMPT [1/9] Dropped existing objects


-- ============================================
-- 2. CREATE DATA TABLES
-- ============================================

CREATE TABLE MERCHANTS (
    merchant_id   VARCHAR2(32) PRIMARY KEY,
    merchant_name VARCHAR2(128) NOT NULL,
    city          VARCHAR2(64),
    category      VARCHAR2(64),
    status        VARCHAR2(32) DEFAULT 'ACTIVE',
    created_at    TIMESTAMP DEFAULT SYSTIMESTAMP
);

CREATE TABLE TRANSACTIONS (
    txn_id      NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    merchant_id VARCHAR2(32) REFERENCES MERCHANTS(merchant_id),
    txn_date    DATE NOT NULL,
    amount      NUMBER(18,2) NOT NULL,
    txn_type    VARCHAR2(32),
    status      VARCHAR2(32),
    card_number VARCHAR2(20),
    created_at  TIMESTAMP DEFAULT SYSTIMESTAMP
);

CREATE TABLE RECONCILIATION_SUMMARY (
    id           NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    batch_date   DATE,
    merchant_id  VARCHAR2(32),
    total_count  NUMBER,
    total_amount NUMBER(18,2),
    updated_at   TIMESTAMP
);

CREATE TABLE SETTLEMENT_LEDGER (
    id              NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    settlement_date DATE,
    merchant_id     VARCHAR2(32),
    net_amount      NUMBER(18,2),
    fee_amount      NUMBER(18,2),
    created_at      TIMESTAMP DEFAULT SYSTIMESTAMP
);

CREATE TABLE EXPORT_STAGING (
    id          NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    merchant_id VARCHAR2(32),
    txn_date    DATE,
    amount      NUMBER(18,2),
    exported_at DATE
);

PROMPT [2/9] Created data tables


-- ============================================
-- 3. INSERT MERCHANTS (100 rows)
-- ============================================

INSERT INTO MERCHANTS (merchant_id, merchant_name, city, category, status)
SELECT
    'M' || LPAD(LEVEL, 4, '0'),
    'Merchant_' || LEVEL,
    CASE MOD(LEVEL, 5)
        WHEN 0 THEN 'Mumbai'
        WHEN 1 THEN 'Delhi'
        WHEN 2 THEN 'Bangalore'
        WHEN 3 THEN 'Chennai'
        ELSE 'Hyderabad'
    END,
    CASE MOD(LEVEL, 4)
        WHEN 0 THEN 'RETAIL'
        WHEN 1 THEN 'ECOMMERCE'
        WHEN 2 THEN 'FOOD'
        ELSE 'TRAVEL'
    END,
    'ACTIVE'
FROM DUAL
CONNECT BY LEVEL <= 100;

COMMIT;
PROMPT [3/9] Inserted 100 merchants


-- ============================================
-- 4. INSERT TRANSACTIONS (100K rows, batched)
-- ============================================

BEGIN
    FOR batch_num IN 0..99 LOOP
        INSERT INTO TRANSACTIONS (merchant_id, txn_date, amount, txn_type, status, card_number, created_at)
        SELECT
            'M' || LPAD(MOD(LEVEL + batch_num * 1000 - 1, 100) + 1, 4, '0'),
            TRUNC(SYSDATE) - MOD(LEVEL + batch_num * 1000, 365),
            ROUND(DBMS_RANDOM.VALUE(10, 50000), 2),
            CASE MOD(LEVEL, 4)
                WHEN 0 THEN 'PURCHASE'
                WHEN 1 THEN 'REFUND'
                WHEN 2 THEN 'AUTH'
                ELSE 'VOID'
            END,
            CASE
                WHEN MOD(LEVEL + batch_num * 1000, 50) = 0 THEN 'FAILED'
                ELSE 'SUCCESS'
            END,
            'XXXX-XXXX-XXXX-' || LPAD(MOD(LEVEL + batch_num * 1000, 9999) + 1, 4, '0'),
            SYSTIMESTAMP - NUMTODSINTERVAL(MOD(LEVEL + batch_num * 1000, 525600), 'MINUTE')
        FROM DUAL
        CONNECT BY LEVEL <= 1000;

        IF MOD(batch_num + 1, 20) = 0 THEN
            COMMIT;
            DBMS_OUTPUT.PUT_LINE('  ... ' || ((batch_num + 1) * 1000) || ' rows inserted');
        END IF;
    END LOOP;
    COMMIT;
END;
/

PROMPT [4/9] Inserted 100K transactions


-- ============================================
-- 5. INDEXES (selective — no index on created_at!)
-- ============================================

CREATE INDEX idx_txn_date ON TRANSACTIONS(txn_date);
CREATE INDEX idx_txn_merchant ON TRANSACTIONS(merchant_id);
-- NOTE: NO index on created_at — this is intentional so reconciliation does a full scan

PROMPT [5/9] Created indexes (NO index on created_at)


-- ============================================
-- 6. GATHER STATISTICS
-- ============================================

BEGIN
    DBMS_STATS.GATHER_TABLE_STATS(USER, 'MERCHANTS');
    DBMS_STATS.GATHER_TABLE_STATS(USER, 'TRANSACTIONS');
    DBMS_STATS.GATHER_TABLE_STATS(USER, 'RECONCILIATION_SUMMARY');
    DBMS_STATS.GATHER_TABLE_STATS(USER, 'SETTLEMENT_LEDGER');
    DBMS_STATS.GATHER_TABLE_STATS(USER, 'EXPORT_STAGING');
END;
/

PROMPT [6/9] Gathered table statistics


-- ============================================
-- 7. PL/SQL PACKAGES (business logic)
-- ============================================

-- 7a. PKG_RECONCILIATION (SLOW: full scan + correlated subquery)
CREATE OR REPLACE PACKAGE PKG_RECONCILIATION AS
    PROCEDURE RUN_RECONCILIATION;
END PKG_RECONCILIATION;
/

CREATE OR REPLACE PACKAGE BODY PKG_RECONCILIATION AS
    PROCEDURE RUN_RECONCILIATION IS
        v_mismatches NUMBER;
        v_dupes      NUMBER;
    BEGIN
        DELETE FROM RECONCILIATION_SUMMARY WHERE batch_date = TRUNC(SYSDATE);

        INSERT INTO RECONCILIATION_SUMMARY (batch_date, merchant_id, total_count, total_amount, updated_at)
        SELECT TRUNC(SYSDATE), t.merchant_id, COUNT(*), SUM(t.amount), SYSTIMESTAMP
        FROM TRANSACTIONS t
        WHERE t.created_at >= SYSTIMESTAMP - INTERVAL '30' DAY
        GROUP BY t.merchant_id;

        SELECT COUNT(*) INTO v_mismatches
        FROM TRANSACTIONS t1
        WHERE t1.created_at >= SYSTIMESTAMP - INTERVAL '30' DAY
          AND t1.amount > (
              SELECT /*+ NO_UNNEST FULL(t2) */ AVG(t2.amount) * 1.5
              FROM TRANSACTIONS t2
              WHERE t2.merchant_id = t1.merchant_id
                AND t2.created_at >= SYSTIMESTAMP - INTERVAL '30' DAY
          );

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

PROMPT [7a/9] Created PKG_RECONCILIATION


-- 7b. PKG_REGULATORY_EXPORT (FAILS: validation error after heavy query)
CREATE OR REPLACE PACKAGE PKG_REGULATORY_EXPORT AS
    PROCEDURE RUN_EXPORT;
END PKG_REGULATORY_EXPORT;
/

CREATE OR REPLACE PACKAGE BODY PKG_REGULATORY_EXPORT AS
    PROCEDURE RUN_EXPORT IS
        v_count   NUMBER;
        v_invalid NUMBER;
    BEGIN
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

PROMPT [7b/9] Created PKG_REGULATORY_EXPORT


-- 7c. PKG_SETTLEMENT (FAST: uses indexed txn_date)
CREATE OR REPLACE PACKAGE PKG_SETTLEMENT AS
    PROCEDURE RUN_DAILY_SETTLEMENT;
END PKG_SETTLEMENT;
/

CREATE OR REPLACE PACKAGE BODY PKG_SETTLEMENT AS
    PROCEDURE RUN_DAILY_SETTLEMENT IS
    BEGIN
        DELETE FROM SETTLEMENT_LEDGER WHERE settlement_date = TRUNC(SYSDATE);

        INSERT INTO SETTLEMENT_LEDGER (settlement_date, merchant_id, net_amount, fee_amount)
        SELECT TRUNC(SYSDATE), t.merchant_id, SUM(t.amount), ROUND(SUM(t.amount) * 0.02, 2)
        FROM TRANSACTIONS t
        WHERE t.txn_date = TRUNC(SYSDATE)
          AND t.status = 'SUCCESS'
        GROUP BY t.merchant_id;

        COMMIT;
    END RUN_DAILY_SETTLEMENT;
END PKG_SETTLEMENT;
/

PROMPT [7c/9] Created PKG_SETTLEMENT


-- 7d. PKG_TXN_SYNC (FAST: simple count)
CREATE OR REPLACE PACKAGE PKG_TXN_SYNC AS
    PROCEDURE RUN_TXN_SYNC;
END PKG_TXN_SYNC;
/

CREATE OR REPLACE PACKAGE BODY PKG_TXN_SYNC AS
    PROCEDURE RUN_TXN_SYNC IS
        v_synced NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_synced
        FROM TRANSACTIONS
        WHERE txn_date = TRUNC(SYSDATE)
          AND status = 'SUCCESS';

        DBMS_OUTPUT.PUT_LINE('TXN_SYNC: Verified ' || v_synced || ' transactions for today');
    END RUN_TXN_SYNC;
END PKG_TXN_SYNC;
/

PROMPT [7d/9] Created PKG_TXN_SYNC


-- ============================================
-- 8. PKG_JOB_RUNNER (wrapper with autonomous logging)
-- ============================================

CREATE OR REPLACE PACKAGE PKG_JOB_RUNNER AS
    FUNCTION  START_BATCH(p_name VARCHAR2, p_expected_mins NUMBER) RETURN NUMBER;
    PROCEDURE FINISH_BATCH(p_id NUMBER, p_status VARCHAR2, p_error VARCHAR2 DEFAULT NULL);
    PROCEDURE EXEC_AND_FINISH_BATCH(p_batch_name VARCHAR2, p_batch_id NUMBER);

    FUNCTION  START_REPORT(p_name VARCHAR2, p_expected_mins NUMBER) RETURN NUMBER;
    PROCEDURE FINISH_REPORT(p_id NUMBER, p_status VARCHAR2, p_error VARCHAR2 DEFAULT NULL);
    PROCEDURE EXEC_AND_FINISH_REPORT(p_report_name VARCHAR2, p_report_id NUMBER);
END PKG_JOB_RUNNER;
/

CREATE OR REPLACE PACKAGE BODY PKG_JOB_RUNNER AS

    FUNCTION START_BATCH(p_name VARCHAR2, p_expected_mins NUMBER) RETURN NUMBER IS
        PRAGMA AUTONOMOUS_TRANSACTION;
        v_id NUMBER;
    BEGIN
        INSERT INTO BatchLog (batch_name, status, start_ts, expected_duration_mins)
        VALUES (p_name, 'RUNNING', SYSTIMESTAMP, p_expected_mins)
        RETURNING id INTO v_id;
        COMMIT;
        RETURN v_id;
    END START_BATCH;

    PROCEDURE FINISH_BATCH(p_id NUMBER, p_status VARCHAR2, p_error VARCHAR2 DEFAULT NULL) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        UPDATE BatchLog
        SET status = p_status, end_ts = SYSTIMESTAMP, error_message = p_error
        WHERE id = p_id;
        COMMIT;
    END FINISH_BATCH;

    PROCEDURE EXEC_AND_FINISH_BATCH(p_batch_name VARCHAR2, p_batch_id NUMBER) IS
    BEGIN
        CASE p_batch_name
            WHEN 'RECONCILIATION_BATCH' THEN PKG_RECONCILIATION.RUN_RECONCILIATION;
            WHEN 'DAILY_SETTLEMENT'     THEN PKG_SETTLEMENT.RUN_DAILY_SETTLEMENT;
            ELSE RAISE_APPLICATION_ERROR(-20099, 'Unknown batch: ' || p_batch_name);
        END CASE;
        FINISH_BATCH(p_batch_id, 'COMPLETED');
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            FINISH_BATCH(p_batch_id, 'FAILED', SQLERRM);
    END EXEC_AND_FINISH_BATCH;

    FUNCTION START_REPORT(p_name VARCHAR2, p_expected_mins NUMBER) RETURN NUMBER IS
        PRAGMA AUTONOMOUS_TRANSACTION;
        v_id NUMBER;
    BEGIN
        INSERT INTO ReportLog (report_name, status, start_ts, expected_duration_mins)
        VALUES (p_name, 'RUNNING', SYSTIMESTAMP, p_expected_mins)
        RETURNING id INTO v_id;
        COMMIT;
        RETURN v_id;
    END START_REPORT;

    PROCEDURE FINISH_REPORT(p_id NUMBER, p_status VARCHAR2, p_error VARCHAR2 DEFAULT NULL) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        UPDATE ReportLog
        SET status = p_status, end_ts = SYSTIMESTAMP, error_message = p_error
        WHERE id = p_id;
        COMMIT;
    END FINISH_REPORT;

    PROCEDURE EXEC_AND_FINISH_REPORT(p_report_name VARCHAR2, p_report_id NUMBER) IS
    BEGIN
        CASE p_report_name
            WHEN 'REGULATORY_EXPORT' THEN PKG_REGULATORY_EXPORT.RUN_EXPORT;
            WHEN 'TXN_SYNC'          THEN PKG_TXN_SYNC.RUN_TXN_SYNC;
            ELSE RAISE_APPLICATION_ERROR(-20099, 'Unknown report: ' || p_report_name);
        END CASE;
        FINISH_REPORT(p_report_id, 'COMPLETED');
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            FINISH_REPORT(p_report_id, 'FAILED', SQLERRM);
    END EXEC_AND_FINISH_REPORT;

END PKG_JOB_RUNNER;
/

PROMPT [8/9] Created PKG_JOB_RUNNER


-- ============================================
-- 9. VERIFY
-- ============================================

SELECT 'MERCHANTS' AS tbl, COUNT(*) AS cnt FROM MERCHANTS
UNION ALL
SELECT 'TRANSACTIONS', COUNT(*) FROM TRANSACTIONS;

SELECT object_name, object_type, status
FROM USER_OBJECTS
WHERE object_type IN ('PACKAGE', 'PACKAGE BODY')
ORDER BY object_name, object_type;

PROMPT [9/9] Phase A setup complete
PROMPT
PROMPT Summary:
PROMPT   - MERCHANTS:              100 rows
PROMPT   - TRANSACTIONS:           100K rows (spread over 1 year)
PROMPT   - No index on created_at  (intentional for slow reconciliation)
PROMPT   - PKG_RECONCILIATION:     slow (full scan + correlated subqueries)
PROMPT   - PKG_REGULATORY_EXPORT:  fails (validation error - amounts > 40000)
PROMPT   - PKG_SETTLEMENT:         fast (indexed txn_date)
PROMPT   - PKG_TXN_SYNC:           fast (simple count)
PROMPT   - PKG_JOB_RUNNER:         wrapper with autonomous transaction logging

EXIT;
