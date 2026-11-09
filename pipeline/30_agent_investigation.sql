-- =====================================================================
-- Step 30: エージェントによる原因調査
-- ROUTE = 'agent' の行を誤差の大きい順に agent_max_rows 件まで調査する。
-- 1件あたり数十秒かかるため、タスクのタイムアウト(USER_TASK_TIMEOUT_MS)は
-- 件数 × 90秒 程度を目安に Pipeline Builder 側で設定する。
-- =====================================================================

USE SCHEMA DECISION_PIPE_DB.DEMO;

TRUNCATE TABLE AGENT_RESULTS;

CALL SP_RUN_AGENT_FOR_ALERTS(NULL);   -- NULL = PIPELINE_CONFIG の agent_max_rows を使用

SELECT STATUS, COUNT(*) AS n, ROUND(MEDIAN(ELAPSED_MS) / 1000, 1) AS median_sec
FROM AGENT_RESULTS GROUP BY STATUS;
