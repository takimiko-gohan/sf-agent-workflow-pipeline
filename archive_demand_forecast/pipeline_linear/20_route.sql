-- =====================================================================
-- Step 20: ルーティング
--   auto  : 原因が特定済み、かつ確信度が高く、追加調査の必要性が低い
--   agent : それ以外(エージェントで調査)
-- 処理上限を超えた agent 行は Step 40 で human に回る
-- 閾値は PIPELINE_CONFIG で調整する
-- =====================================================================

USE SCHEMA DECISION_PIPE_DB.DEMO;

TRUNCATE TABLE ROUTED_ALERTS;

INSERT INTO ROUTED_ALERTS
  (ALERT_ID, ALERT_TEXT, ERROR_RATE, CAUSE, CAUSE_CONFIDENCE, NEEDS_INVESTIGATION_PROB, ROUTE)
WITH cfg AS (
  SELECT
    MAX(IFF(KEY = 'auto_conf_min', VALUE, NULL)) AS auto_conf_min,
    MAX(IFF(KEY = 'auto_inv_max',  VALUE, NULL)) AS auto_inv_max
  FROM PIPELINE_CONFIG
)
SELECT
  a.ALERT_ID, a.ALERT_TEXT, a.ERROR_RATE,
  d.CAUSE, d.CAUSE_CONFIDENCE, d.NEEDS_INVESTIGATION_PROB,
  CASE
    WHEN d.CAUSE IS NOT NULL
     AND d.CAUSE <> 'unknown'
     AND d.CAUSE_CONFIDENCE >= cfg.auto_conf_min
     AND d.NEEDS_INVESTIGATION_PROB < cfg.auto_inv_max
      THEN 'auto'
    ELSE 'agent'
  END AS ROUTE
FROM FORECAST_ALERTS a
LEFT JOIN DECISION_RESULTS d USING (ALERT_ID)
CROSS JOIN cfg;

SELECT ROUTE, COUNT(*) AS n FROM ROUTED_ALERTS GROUP BY ROUTE ORDER BY ROUTE;
