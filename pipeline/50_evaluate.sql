-- =====================================================================
-- Step 50: 正解ラベルとの突合・評価指標の記録
-- 見たい指標:
--   ・判定モデル単体の正解率(全件を判定モデルだけで処理した場合)
--   ・ルート別の正解率(auto / agent)と、人手に回った割合
--   ・本文に当日状況があるか(HAS_CONTEXT)で精度がどう変わるか
-- =====================================================================

USE SCHEMA DECISION_PIPE_DB.DEMO;

CREATE OR REPLACE TEMPORARY TABLE TMP_EVAL AS
SELECT
  f.ALERT_ID, a.HAS_CONTEXT, l.TRUE_CAUSE,
  d.DECISION_MODEL, d.CAUSE AS DECISION_CAUSE,
  f.ROUTE, f.FINAL_ROUTE, f.FINAL_CAUSE
FROM FINAL_RESULTS f
JOIN FORECAST_ALERTS a USING (ALERT_ID)
JOIN ALERT_LABELS    l USING (ALERT_ID)
LEFT JOIN DECISION_RESULTS d USING (ALERT_ID);

-- 指標を履歴テーブルへ追記
INSERT INTO PIPELINE_RUN_LOG (METRIC, DIM, VALUE)
SELECT 'decision_only_accuracy', MAX(DECISION_MODEL),
       AVG(IFF(DECISION_CAUSE = TRUE_CAUSE, 1, 0))
FROM TMP_EVAL
UNION ALL
SELECT 'route_share', FINAL_ROUTE, COUNT(*) / SUM(COUNT(*)) OVER ()
FROM TMP_EVAL GROUP BY FINAL_ROUTE
UNION ALL
SELECT 'route_accuracy', FINAL_ROUTE, AVG(IFF(FINAL_CAUSE = TRUE_CAUSE, 1, 0))
FROM TMP_EVAL WHERE FINAL_ROUTE IN ('auto', 'agent') GROUP BY FINAL_ROUTE
UNION ALL
SELECT 'automated_accuracy', 'auto+agent', AVG(IFF(FINAL_CAUSE = TRUE_CAUSE, 1, 0))
FROM TMP_EVAL WHERE FINAL_ROUTE IN ('auto', 'agent');

-- 今回の結果サマリ
SELECT
  DECISION_MODEL,
  COUNT(*)                                                           AS alerts,
  ROUND(AVG(IFF(DECISION_CAUSE = TRUE_CAUSE, 1, 0)), 3)              AS decision_only_acc,
  ROUND(COUNT_IF(FINAL_ROUTE = 'auto')  / COUNT(*), 3)               AS share_auto,
  ROUND(COUNT_IF(FINAL_ROUTE = 'agent') / COUNT(*), 3)               AS share_agent,
  ROUND(COUNT_IF(FINAL_ROUTE = 'human') / COUNT(*), 3)               AS share_human,
  ROUND(AVG(IFF(FINAL_ROUTE IN ('auto','agent'),
                IFF(FINAL_CAUSE = TRUE_CAUSE, 1, 0), NULL)), 3)      AS automated_acc
FROM TMP_EVAL
GROUP BY DECISION_MODEL;

-- 当日状況の有無 × ルート別の正解率
SELECT HAS_CONTEXT, FINAL_ROUTE, COUNT(*) AS n,
       ROUND(AVG(IFF(FINAL_CAUSE = TRUE_CAUSE, 1, 0)), 3) AS acc
FROM TMP_EVAL
GROUP BY 1, 2 ORDER BY 1, 2;

-- 混同行列(判定モデル単体)
SELECT TRUE_CAUSE, DECISION_CAUSE, COUNT(*) AS n
FROM TMP_EVAL GROUP BY 1, 2 ORDER BY 1, 2;
