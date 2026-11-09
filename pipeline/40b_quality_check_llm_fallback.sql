-- =====================================================================
-- Step 40b: 品質チェック(汎用LLM / フォールバック)
-- 40a と同じロジックで、根拠スコア(0〜2)を汎用LLMの構造化出力で付ける。
-- モデル名は自アカウントで AI_COMPLETE に使えるものに置き換える。
-- =====================================================================

USE SCHEMA DECISION_PIPE_DB.DEMO;

TRUNCATE TABLE FINAL_RESULTS;

INSERT INTO FINAL_RESULTS (ALERT_ID, ROUTE, FINAL_ROUTE, FINAL_CAUSE, QUALITY_SCORE, QUALITY_RAW)
WITH cfg AS (
  SELECT VALUE AS quality_min FROM PIPELINE_CONFIG WHERE KEY = 'quality_min'
),
q0 AS (
  SELECT
    ar.ALERT_ID, ar.AGENT_CAUSE,
    TRY_PARSE_JSON(AI_COMPLETE(
      model  => 'claude-sonnet-5',
      prompt => '次の調査結果の原因判定が、確認したデータの数値で裏付けられているかを 0〜2 で採点してください。'
             || '0=根拠がない/推測のみ、1=一部の根拠のみ、2=数値で明確に裏付けられている。'
             || ' アラート: ' || r.ALERT_TEXT || ' / 調査結果: ' || ar.ANSWER_TEXT,
      model_parameters => {'temperature': 0},
      response_format => {
        'type': 'json',
        'schema': {
          'type': 'object',
          'properties': {'score': {'type': 'number'}},
          'required': ['score']
        }
      }
    )) AS j0
  FROM AGENT_RESULTS ar
  JOIN ROUTED_ALERTS r USING (ALERT_ID)
  WHERE ar.STATUS = 'ok' AND ar.AGENT_CAUSE IS NOT NULL
),
q AS (
  SELECT ALERT_ID, AGENT_CAUSE, j0,
         COALESCE(j0:structured_output[0]:raw_message:score, j0:score)::FLOAT AS score
  FROM q0
)
SELECT
  r.ALERT_ID,
  r.ROUTE,
  CASE
    WHEN r.ROUTE = 'auto' THEN 'auto'
    WHEN q.score >= cfg.quality_min THEN 'agent'
    ELSE 'human'
  END,
  CASE
    WHEN r.ROUTE = 'auto' THEN r.CAUSE
    WHEN q.score >= cfg.quality_min THEN q.AGENT_CAUSE
    ELSE NULL
  END,
  q.score,
  q.j0
FROM ROUTED_ALERTS r
LEFT JOIN q USING (ALERT_ID)
CROSS JOIN cfg;

SELECT FINAL_ROUTE, COUNT(*) AS n FROM FINAL_RESULTS GROUP BY 1 ORDER BY 1;
