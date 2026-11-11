-- =====================================================================
-- 99_teardown.sql
-- SaaSサポート版の検証環境を削除する
-- =====================================================================

-- ---------- decider-2b のサービスとモデル(GPU 課金を止める) ----------
USE ROLE DECISION_PIPE_ROLE;
DROP SERVICE IF EXISTS DECISION_PIPE_DB.SUPPORT.DECIDER_2B_SVC;
DROP MODEL IF EXISTS DECISION_PIPE_DB.SUPPORT.DECIDER_2B;

USE ROLE ACCOUNTADMIN;
-- 同じプールを他の用途(公式サンプルのベンチマークなど)で使っていない場合のみ
DROP COMPUTE POOL IF EXISTS DECIDER_BENCH_GPU_POOL;
DROP COMPUTE POOL IF EXISTS DECIDER_BENCH_BUILD_POOL;
DROP EXTERNAL ACCESS INTEGRATION IF EXISTS DECIDER_BENCH_BUILD_EAI;

-- ---------- スキーマ(Pipeline Builder の DCM プロジェクト・タスクも一緒に消える) ----------
USE ROLE DECISION_PIPE_ROLE;
DROP SCHEMA IF EXISTS DECISION_PIPE_DB.SUPPORT;

-- 検証環境ごと削除する場合
-- USE ROLE ACCOUNTADMIN;
-- DROP DATABASE IF EXISTS DECISION_PIPE_DB;
-- DROP WAREHOUSE IF EXISTS DECISION_PIPE_WH;
-- DROP ROLE IF EXISTS DECISION_PIPE_ROLE;
