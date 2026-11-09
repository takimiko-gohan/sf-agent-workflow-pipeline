-- =====================================================================
-- Step 40a: エージェント回答の品質チェックと最終結果の確定(snowflake-decision)
--   auto                         → 判定モデルの原因を採用
--   agent かつ 根拠スコア >= 閾値 → エージェントの原因を採用
--   それ以外(未処理・失敗・低スコア)→ human(人手レビュー)
-- snowflake-decision が使えない場合は 40b を使う
-- =====================================================================

USE SCHEMA DECISION_PIPE_DB.DEMO;

TRUNCATE TABLE FINAL_RESULTS;

INSERT INTO FINAL_RESULTS (ALERT_ID, ROUTE, FINAL_ROUTE, FINAL_CAUSE, QUALITY_SCORE, QUALITY_RAW)
WITH cfg AS (
  SELECT VALUE AS quality_min FROM PIPELINE_CONFIG WHERE KEY = 'quality_min'
),
q AS (
  SELECT
    ar.ALERT_ID, ar.AGENT_CAUSE,
    TRY_PARSE_JSON(AI_COMPLETE(
      model  => 'snowflake-decision',
      prompt => TO_JSON({
        'state': 'アラート: ' || r.ALERT_TEXT || ' / 調査結果: ' || ar.ANSWER_TEXT,
        'questions': {
          'grounded': {
            'type': 'score',
            'instructions': '調査結果の原因判定は、確認したデータの数値によって裏付けられているか',
            'criteria': ['根拠がない、または推測のみ', '一部の根拠のみ', 'データの数値で明確に裏付けられている']
          }
        }
      })
    )) AS qj
  FROM AGENT_RESULTS ar
  JOIN ROUTED_ALERTS r USING (ALERT_ID)
  WHERE ar.STATUS = 'ok' AND ar.AGENT_CAUSE IS NOT NULL
)
SELECT
  r.ALERT_ID,
  r.ROUTE,
  CASE
    WHEN r.ROUTE = 'auto' THEN 'auto'
    WHEN q.qj:answers:grounded:score::FLOAT >= cfg.quality_min THEN 'agent'
    ELSE 'human'
  END AS FINAL_ROUTE,
  CASE
    WHEN r.ROUTE = 'auto' THEN r.CAUSE
    WHEN q.qj:answers:grounded:score::FLOAT >= cfg.quality_min THEN q.AGENT_CAUSE
    ELSE NULL
  END AS FINAL_CAUSE,
  q.qj:answers:grounded:score::FLOAT,
  q.qj
FROM ROUTED_ALERTS r
LEFT JOIN q USING (ALERT_ID)
CROSS JOIN cfg;

SELECT FINAL_ROUTE, COUNT(*) AS n FROM FINAL_RESULTS GROUP BY 1 ORDER BY 1;
