-- =====================================================================
-- Step 10a: 判定(snowflake-decision / Private Preview)
-- Pipeline Builder の SQL カードに割り当てる。10a / 10b / 10c のどれか1つを使う。
-- 前提: アカウントで snowflake-decision が有効化されていること
-- =====================================================================

USE SCHEMA DECISION_PIPE_DB.DEMO;

TRUNCATE TABLE DECISION_RESULTS;

INSERT INTO DECISION_RESULTS
  (ALERT_ID, DECISION_MODEL, CAUSE, CAUSE_CONFIDENCE, CAUSE_PROBS, NEEDS_INVESTIGATION_PROB, RAW)
WITH d AS (
  SELECT
    a.ALERT_ID,
    -- 戻り値の型は Private Preview ドキュメントで要確認。文字列前提で TRY_PARSE_JSON している
    TRY_PARSE_JSON(AI_COMPLETE(
      model  => 'snowflake-decision',
      prompt => TO_JSON({
        'state': a.ALERT_TEXT,
        'questions': {
          'cause': {
            'type': 'choice',
            'instructions': '需要予測が外れた主な原因はどれか',
            'criteria': {
              'promo':   '販促・キャンペーンの実施で需要が増えた',
              'weather': '猛暑や豪雨など天候で需要が増減した',
              'stock':   '欠品・在庫不足で実績が抑えられた',
              'unknown': 'アラート本文からは原因を特定できない'
            }
          },
          'needs_investigation': {
            'type': 'noul',
            'instructions': 'アラート本文だけでは原因を確定できず、追加データの調査が必要である'
          }
        }
      })
    )) AS j
  FROM FORECAST_ALERTS a
)
SELECT
  ALERT_ID,
  'snowflake-decision',
  j:answers:cause:choice::STRING,
  j:answers:cause:confidence::FLOAT,
  j:answers:cause:probabilities,
  j:answers:needs_investigation:noul::FLOAT,
  j
FROM d;

-- 解析できなかった行があれば RAW を確認する
SELECT COUNT(*) AS n, COUNT_IF(CAUSE IS NULL) AS n_unparsed FROM DECISION_RESULTS;
