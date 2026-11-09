-- =====================================================================
-- 00_setup.sql
-- 検証用のロール・ウェアハウス・DB/スキーマと権限を作成する
-- 実行ロール: ACCOUNTADMIN(またはロール/WH/DB作成権限を持つロール)
-- =====================================================================

USE ROLE ACCOUNTADMIN;

-- ---------- 名前の設定(必要に応じて変更) ----------
SET pipe_role = 'DECISION_PIPE_ROLE';
SET pipe_wh   = 'DECISION_PIPE_WH';
SET pipe_db   = 'DECISION_PIPE_DB';
SET pipe_sch  = 'DECISION_PIPE_DB.DEMO';
SET my_user   = CURRENT_USER();

-- ---------- ロール ----------
CREATE ROLE IF NOT EXISTS IDENTIFIER($pipe_role)
  COMMENT = 'Decision + Cortex Agent パイプライン検証用';
GRANT ROLE IDENTIFIER($pipe_role) TO USER IDENTIFIER($my_user);
GRANT ROLE IDENTIFIER($pipe_role) TO ROLE SYSADMIN;

-- ---------- ウェアハウス ----------
CREATE WAREHOUSE IF NOT EXISTS IDENTIFIER($pipe_wh)
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE;
GRANT USAGE, OPERATE ON WAREHOUSE IDENTIFIER($pipe_wh) TO ROLE IDENTIFIER($pipe_role);

-- ---------- DB / スキーマ(所有権を検証ロールへ) ----------
CREATE DATABASE IF NOT EXISTS IDENTIFIER($pipe_db);
GRANT OWNERSHIP ON DATABASE IDENTIFIER($pipe_db) TO ROLE IDENTIFIER($pipe_role) COPY CURRENT GRANTS;

USE ROLE IDENTIFIER($pipe_role);
CREATE SCHEMA IF NOT EXISTS IDENTIFIER($pipe_sch);
USE ROLE ACCOUNTADMIN;

-- スキーマ所有者は CREATE TASK / CREATE AGENT / CREATE SEMANTIC VIEW /
-- CREATE PROCEDURE / CREATE DCM PROJECT をすべて持つため個別付与は不要。
-- タスクの実行(Pipeline Builder の Deploy 後の実行)にはアカウント権限が必要。
GRANT EXECUTE TASK ON ACCOUNT TO ROLE IDENTIFIER($pipe_role);

-- Cortex AI 関数(AI_COMPLETE)と Cortex Agents の利用権限
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE IDENTIFIER($pipe_role);

-- ---------- (任意)クロスリージョン推論 ----------
-- 使いたいモデルが自リージョンで提供されていない場合のみ有効化する。
-- 組織のデータ所在ポリシーを確認してから実行すること。
-- ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'ANY_REGION';

-- ---------- 確認 ----------
USE ROLE IDENTIFIER($pipe_role);
USE WAREHOUSE IDENTIFIER($pipe_wh);
USE SCHEMA IDENTIFIER($pipe_sch);
SELECT CURRENT_ROLE(), CURRENT_WAREHOUSE(), CURRENT_DATABASE(), CURRENT_SCHEMA();
