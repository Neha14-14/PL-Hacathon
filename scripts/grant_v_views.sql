-- Grant SELECT on V$ underlying views to creditplus (run as SYSDBA / SYS).
-- Required for Phase B live diagnostics (agent/diagnostics.py).
-- Without these, RCA uses fallback simulated AWR.
-- Run (as SYSDBA): sqlplus sys/YourSysPassword@localhost:1521/freepdb1 as sysdba @scripts/grant_v_views.sql
-- Note: Oracle 26ai Free may use different object names; if grant fails, check SYS.ALL_OBJECTS for V_$%.

GRANT SELECT ON V_$SQL TO creditplus;
GRANT SELECT ON V_$SQLTEXT TO creditplus;
GRANT SELECT ON V_$SQL_PLAN TO creditplus;
GRANT SELECT ON V_$SESSION TO creditplus;
GRANT SELECT ON V_$SESSION_EVENT TO creditplus;

-- Optional: create synonyms in creditplus schema if using V_$ names
-- (V$ are public synonyms pointing to V_$ in SYS, so creditplus can use V$SQL after grant on V_$SQL)
EXIT;
