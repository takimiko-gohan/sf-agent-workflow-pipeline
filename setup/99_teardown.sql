-- =====================================================================
-- 99_teardown.sql
-- お片付け
-- =====================================================================

USE ROLE ACCOUNTADMIN;
DROP DATABASE IF EXISTS DECISION_PIPE_DB;
DROP WAREHOUSE IF EXISTS DECISION_PIPE_WH;
DROP ROLE IF EXISTS DECISION_PIPE_ROLE;