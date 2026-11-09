-- =====================================================================
-- 99_teardown.sql
-- 検証環境を削除する。Pipeline Builder で作成した DCM プロジェクトや
-- タスクグラフも DB ごと削除される(DCM プロジェクトを同じスキーマに置いた場合)。
-- decider-2b を使った場合は、リポジトリの sql/99_teardown.sql も実行して GPU プールを止めること。
-- =====================================================================

USE ROLE ACCOUNTADMIN;

DROP DATABASE IF EXISTS DECISION_PIPE_DB;
DROP WAREHOUSE IF EXISTS DECISION_PIPE_WH;
DROP ROLE IF EXISTS DECISION_PIPE_ROLE;
