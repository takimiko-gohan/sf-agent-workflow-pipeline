-- =====================================================================
-- Step 10b: 判定(汎用LLM + 構造化出力 / フォールバック)
-- snowflake-decision が未有効化でもパイプライン全体を動かせるようにする代替手段。
-- 注意: ここでの confidence / 確率は LLM の自己申告値で、Decision モデルの
--       確率ほど当てにならない。閾値の比較検証には向かない点に留意。
-- モデル名は自アカウント・リージョンで AI_COMPLETE に使えるものに置き換える。
-- =====================================================================

USE SCHEMA DECISION_PIPE_DB.DEMO;

TRUNCATE TABLE DECISION_RESULTS;

INSERT INTO DECISION_RESULTS
  (ALERT_ID, DECISION_MODEL, CAUSE, CAUSE_CONFIDENCE, CAUSE_PROBS, NEEDS_INVESTIGATION_PROB, RAW)
WITH d AS (
  SELECT
    a.ALERT_ID,
    TRY_PARSE_JSON(AI_COMPLETE(
      model  => 'claude-sonnet-5',
      prompt => '次の需要予測アラートを読み、予測が外れた主な原因を分類してください。'
             || 'promo=販促・キャンペーン、weather=猛暑や豪雨などの天候、stock=欠品・在庫不足、'
             || 'unknown=本文からは特定できない。confidence は分類の確からしさ(0〜1)、'
             || 'needs_investigation_prob は本文だけでは確定できず追加調査が必要な確率(0〜1)。'
             || ' アラート: ' || a.ALERT_TEXT,
      model_parameters => {'temperature': 0},
      response_format => {
        'type': 'json',
        'schema': {
          'type': 'object',
          'properties': {
            'cause': {'type': 'string', 'enum': ['promo', 'weather', 'stock', 'unknown']},
            'confidence': {'type': 'number'},
            'needs_investigation_prob': {'type': 'number'}
          },
          'required': ['cause', 'confidence', 'needs_investigation_prob']
        }
      }
    )) AS j0
  FROM FORECAST_ALERTS a
),
n AS (
  -- show_details 付きのラッパー形式で返る場合にも対応
  SELECT ALERT_ID, COALESCE(j0:structured_output[0]:raw_message, j0) AS j, j0
  FROM d
)
SELECT
  ALERT_ID,
  'llm-fallback',
  j:cause::STRING,
  j:confidence::FLOAT,
  NULL,
  j:needs_investigation_prob::FLOAT,
  j0
FROM n;

SELECT COUNT(*) AS n, COUNT_IF(CAUSE IS NULL) AS n_unparsed FROM DECISION_RESULTS;
