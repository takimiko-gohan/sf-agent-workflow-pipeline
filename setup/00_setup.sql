-- =====================================================================
-- 00_setup.sql
-- 検証用のロール・ウェアハウス・DB と、SaaSサポート版のスキーマを作成する
-- 実行ロール: ACCOUNTADMIN(またはロール/WH/DB作成権限を持つロール)
-- 需要予測版(archive_demand_forecast)を実行済みでもそのまま流せる(冪等)
-- =====================================================================

USE ROLE ACCOUNTADMIN;

SET pipe_role = 'DECISION_PIPE_ROLE';
SET pipe_wh   = 'DECISION_PIPE_WH';
SET pipe_db   = 'DECISION_PIPE_DB';
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

-- ---------- DB(所有権を検証ロールへ) ----------
CREATE DATABASE IF NOT EXISTS IDENTIFIER($pipe_db);
GRANT OWNERSHIP ON DATABASE IDENTIFIER($pipe_db) TO ROLE IDENTIFIER($pipe_role) COPY CURRENT GRANTS;

-- タスク実行(Pipeline Builder の Deploy 後の実行)に必要なアカウント権限
GRANT EXECUTE TASK ON ACCOUNT TO ROLE IDENTIFIER($pipe_role);

-- AI_COMPLETE / Cortex Search / Cortex Agents の利用権限
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE IDENTIFIER($pipe_role);

-- (任意)使いたいモデルが自リージョンで提供されていない場合のみ。データ所在ポリシーを確認してから
-- ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'ANY_REGION';

-- ---------- スキーマ ----------
-- スキーマ所有者は CREATE TASK / AGENT / SEMANTIC VIEW / CORTEX SEARCH SERVICE /
-- PROCEDURE / DCM PROJECT をすべて持つため、個別付与は不要
USE ROLE IDENTIFIER($pipe_role);
CREATE SCHEMA IF NOT EXISTS DECISION_PIPE_DB.SUPPORT
  COMMENT = 'SaaSカスタマーサポート版';

USE WAREHOUSE IDENTIFIER($pipe_wh);
USE SCHEMA DECISION_PIPE_DB.SUPPORT;
SELECT CURRENT_ROLE(), CURRENT_WAREHOUSE(), CURRENT_DATABASE(), CURRENT_SCHEMA();
