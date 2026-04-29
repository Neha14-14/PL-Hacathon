-- Phase 2: Create BatchLog and ReportLog and insert dummy data
-- Run with: run_sqlcl.sh creditplus/CreditPlus123@localhost:1521/freepdb1 @scripts/phase2_setup.sql

-- 2.4 BatchLog table
CREATE TABLE BatchLog (
  id                     NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  batch_name             VARCHAR2(128) NOT NULL,
  status                 VARCHAR2(32)  NOT NULL,
  start_ts               TIMESTAMP,
  end_ts                 TIMESTAMP,
  expected_duration_mins NUMBER,
  error_message          VARCHAR2(4000),
  created_at             TIMESTAMP DEFAULT SYSTIMESTAMP
);
COMMENT ON TABLE BatchLog IS 'Log of batch job executions for monitoring';
COMMENT ON COLUMN BatchLog.status IS 'RUNNING, COMPLETED, FAILED';
COMMENT ON COLUMN BatchLog.expected_duration_mins IS 'Expected completion time in minutes';

-- 2.5 ReportLog table
CREATE TABLE ReportLog (
  id                     NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  report_name            VARCHAR2(128) NOT NULL,
  status                 VARCHAR2(32)  NOT NULL,
  start_ts               TIMESTAMP,
  end_ts                 TIMESTAMP,
  expected_duration_mins NUMBER,
  error_message          VARCHAR2(4000),
  created_at             TIMESTAMP DEFAULT SYSTIMESTAMP
);
COMMENT ON TABLE ReportLog IS 'Log of report job executions for monitoring';
COMMENT ON COLUMN ReportLog.status IS 'RUNNING, COMPLETED, FAILED';
COMMENT ON COLUMN ReportLog.expected_duration_mins IS 'Expected completion time in minutes';

-- 2.6 Normal completed batches
INSERT INTO BatchLog (batch_name, status, start_ts, end_ts, expected_duration_mins) VALUES
('DAILY_SETTLEMENT', 'COMPLETED', SYSTIMESTAMP - INTERVAL '2' HOUR, SYSTIMESTAMP - INTERVAL '2' HOUR + INTERVAL '45' MINUTE, 60);
INSERT INTO BatchLog (batch_name, status, start_ts, end_ts, expected_duration_mins) VALUES
('CARD_TXN_SYNC', 'COMPLETED', SYSTIMESTAMP - INTERVAL '1' HOUR, SYSTIMESTAMP - INTERVAL '1' HOUR + INTERVAL '5' MINUTE, 10);
INSERT INTO BatchLog (batch_name, status, start_ts, end_ts, expected_duration_mins) VALUES
('FEE_CALC', 'COMPLETED', SYSTIMESTAMP - INTERVAL '30' MINUTE, SYSTIMESTAMP - INTERVAL '30' MINUTE + INTERVAL '2' MINUTE, 5);

-- 2.7 Normal completed reports
INSERT INTO ReportLog (report_name, status, start_ts, end_ts, expected_duration_mins) VALUES
('MERCHANT_STATEMENT', 'COMPLETED', SYSTIMESTAMP - INTERVAL '3' HOUR, SYSTIMESTAMP - INTERVAL '3' HOUR + INTERVAL '15' MINUTE, 20);
INSERT INTO ReportLog (report_name, status, start_ts, end_ts, expected_duration_mins) VALUES
('DAILY_REVENUE', 'COMPLETED', SYSTIMESTAMP - INTERVAL '1' HOUR, SYSTIMESTAMP - INTERVAL '1' HOUR + INTERVAL '8' MINUTE, 10);

-- 2.8 Long-running batch (anomaly: RUNNING, 25 min elapsed, 10 min expected)
INSERT INTO BatchLog (batch_name, status, start_ts, end_ts, expected_duration_mins) VALUES
('RECONCILIATION_BATCH', 'RUNNING', SYSTIMESTAMP - INTERVAL '25' MINUTE, NULL, 10);

-- 2.9 Failed report (anomaly)
INSERT INTO ReportLog (report_name, status, start_ts, end_ts, expected_duration_mins, error_message) VALUES
('REGULATORY_EXPORT', 'FAILED', SYSTIMESTAMP - INTERVAL '15' MINUTE, SYSTIMESTAMP - INTERVAL '14' MINUTE, 5, 'ORA-01652: unable to extend temp segment');

COMMIT;

-- 2.10 Verify
SELECT id, batch_name, status, start_ts, expected_duration_mins FROM BatchLog ORDER BY id;
SELECT id, report_name, status, start_ts, expected_duration_mins FROM ReportLog ORDER BY id;

EXIT;
