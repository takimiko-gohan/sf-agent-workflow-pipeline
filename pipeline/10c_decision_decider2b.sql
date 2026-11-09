-- =====================================================================
-- Step 10c: 判定(decider-2b を Model Registry → SPCS サービスで実行)
-- 前提: Snowflake-Labs/decision-models-in-snowflake-model-registry の
--       「Real-time inference service」手順で DECIDER_2B_SVC を起動済みであること
--       https://github.com/Snowflake-Labs/decision-models-in-snowflake-model-registry
-- 注意: サービス稼働中は GPU_NV_S ノードが常時課金される。検証後は必ず停止する。
--       DECISION_PIPE_ROLE にサービスの利用権限を付与しておくこと。
-- 下のサービス名はリポジトリ既定値(DECIDER_BENCH.BENCH)。変更した場合は合わせる。
-- =====================================================================

USE SCHEMA DECISION_PIPE_DB.DEMO;

TRUNCATE TABLE DECISION_RESULTS;

INSERT INTO DECISION_RESULTS
  (ALERT_ID, DECISION_MODEL, CAUSE, CAUSE_CONFIDENCE, CAUSE_PROBS, NEEDS_INVESTIGATION_PROB, RAW)
WITH d AS (
  SELECT
    a.ALERT_ID,
    DECIDER_BENCH.BENCH.DECIDER_2B_SVC!SYSTEM_ONE(
      TO_JSON(a.ALERT_TEXT),                         -- STATE_JSON(JSON文字列)
      TO_JSON({                                       -- QUESTIONS_JSON
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
          'instructions': 'アラート本文だけでは原因を確定できず、追加データの調査が必要である',
          'criteria': {'true': '追加調査が必要', 'false': '本文だけで確定できる'}
        }
      })
    ) AS out
  FROM FORECAST_ALERTS a
),
p AS (
  SELECT ALERT_ID, TRY_PARSE_JSON(out:ANSWER_JSON::STRING) AS j FROM d
)
SELECT
  ALERT_ID,
  'decider-2b',
  -- 応答は snowflake-decision と同じ answers 形式を想定。初回は RAW を見て経路を確認すること
  j:answers:cause:choice::STRING,
  j:answers:cause:confidence::FLOAT,
  j:answers:cause:probabilities,
  j:answers:needs_investigation:noul::FLOAT,
  j
FROM p;

SELECT COUNT(*) AS n, COUNT_IF(CAUSE IS NULL) AS n_unparsed FROM DECISION_RESULTS;
-- n_unparsed が多い場合: SELECT RAW FROM DECISION_RESULTS LIMIT 3; で構造を確認する
