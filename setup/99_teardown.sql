-- =====================================================================
-- 99_teardown.sql
-- SaaSサポート版のスキーマを削除する。Pipeline Builder の DCM プロジェクトと
-- タスクグラフを SUPPORT スキーマに置いた場合は、それらも一緒に削除される。
-- =====================================================================

USE ROLE DECISION_PIPE_ROLE;
DROP SCHEMA IF EXISTS DECISION_PIPE_DB.SUPPORT;

-- 検証環境ごと削除する場合(需要予測版の DEMO スキーマも消える)
-- USE ROLE ACCOUNTADMIN;
-- DROP DATABASE IF EXISTS DECISION_PIPE_DB;
-- DROP WAREHOUSE IF EXISTS DECISION_PIPE_WH;
-- DROP ROLE IF EXISTS DECISION_PIPE_ROLE;
