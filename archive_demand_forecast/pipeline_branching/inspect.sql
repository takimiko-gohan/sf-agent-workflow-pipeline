-- =====================================================================
-- inspect.sql
-- グラフ実行後の確認クエリ
-- =====================================================================

USE ROLE DECISION_PIPE_ROLE;
USE WAREHOUSE DECISION_PIPE_WH;
USE SCHEMA DECISION_PIPE_DB.DEMO;

-- 1. 実行ごとに通った経路(ファイナライザーが記録)
SELECT LOGGED_AT, BATCH_DATES, STATUS, PATH
FROM V_RUN_PATH
ORDER BY LOGGED_AT DESC
LIMIT 10;

-- 2. タスク履歴を直接見る(RUN_TASK_STATES が空のときや、最新の実行を詳しく見たいとき)
--    TASK_HISTORY は反映に少し時間がかかることがある
SELECT GRAPH_RUN_GROUP_ID, NAME, STATE, RETURN_VALUE, ERROR_MESSAGE, QUERY_START_TIME, COMPLETED_TIME
FROM TABLE(DECISION_PIPE_DB.INFORMATION_SCHEMA.TASK_HISTORY(
       SCHEDULED_TIME_RANGE_START => DATEADD('hour', -6, CURRENT_TIMESTAMP()),
       RESULT_LIMIT => 200))
ORDER BY SCHEDULED_TIME DESC, QUERY_START_TIME;

-- 3. 実行サマリ(判定モデル・品質チェックモデル・ルート別件数・自動処理分の正解率)
SELECT LOGGED_AT, BATCH_DATES, N_ALERTS, DECISION_MODEL, QUALITY_MODEL,
       N_AUTO, N_AGENT, N_HUMAN, ROUND(AUTOMATED_ACC, 3) AS AUTOMATED_ACC, STATUS
FROM RUN_SUMMARY
ORDER BY LOGGED_AT DESC;

-- 4. 人手レビューキュー(理由別)
SELECT REASON, SOURCE_TASK, COUNT(*) AS N
FROM HUMAN_REVIEW_QUEUE
GROUP BY 1, 2
ORDER BY 1, 2;

-- 5. イベントログ
SELECT LOGGED_AT, TASK, EVENT, DETAIL
FROM PIPELINE_EVENTS
ORDER BY LOGGED_AT DESC
LIMIT 50;

-- 6. 残りのバッチ
SELECT * FROM V_BATCH_PREVIEW ORDER BY SALES_DATE;

-- 7. 累計の評価(全バッチ通算。pipeline_linear/50_evaluate.sql と同じ観点)
SELECT
  d.DECISION_MODEL,
  COUNT(*)                                                        AS alerts,
  ROUND(AVG(IFF(d.CAUSE = l.TRUE_CAUSE, 1, 0)), 3)                AS decision_only_acc,
  ROUND(COUNT_IF(f.FINAL_ROUTE = 'auto')  / COUNT(*), 3)          AS share_auto,
  ROUND(COUNT_IF(f.FINAL_ROUTE = 'agent') / COUNT(*), 3)          AS share_agent,
  ROUND(COUNT_IF(f.FINAL_ROUTE = 'human') / COUNT(*), 3)          AS share_human,
  ROUND(AVG(IFF(f.FINAL_ROUTE IN ('auto','agent'),
                IFF(f.FINAL_CAUSE = l.TRUE_CAUSE, 1, 0), NULL)), 3) AS automated_acc
FROM FINAL_RESULTS f
JOIN ALERT_LABELS l USING (ALERT_ID)
LEFT JOIN DECISION_RESULTS d USING (ALERT_ID)
GROUP BY d.DECISION_MODEL;
