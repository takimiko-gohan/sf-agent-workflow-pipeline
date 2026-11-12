-- =====================================================================
-- T41_QUALITY_CHECK  [.sql ファイル]
-- 送信候補を decider-2b で品質チェックする。問い合わせ・返信案・参照情報を英訳し
-- (問い合わせは T07 の英訳を再利用)、JSON オブジェクトにまとめて STATE として渡す。
--   grounded : score(3段階の期待値 0〜2)— 参照情報で裏付けられているか
--   resolves : noul — 質問に直接答えているか
--   risky    : noul — 返金・期日の約束など、担当者の承認が必要な内容を含むか
-- サービス未起動・シナリオの強制失敗・全件解析不能ならタスクが失敗し、T42 が汎用LLMで採点し直す。
--
-- Pipeline Builder の設定
--   種類                  : SQL file(このファイル)
--   Predecessors          : T40_AUTO_ANSWER
--   Condition(WHEN)      : SYSTEM$PREDECESSORS_STATE('ALL_SUCCEEDED')(既定)
-- =====================================================================
USE SCHEMA DECISION_PIPE_DB.SUPPORT;

-- シナリオ quality_down: 強制失敗
SELECT TO_NUMBER(IFF(CFG('force_quality_failure') >= 1,
                     '強制失敗: シナリオ quality_down(decider-2b 停止の想定)', '0'));

DELETE FROM QUALITY_SCORES WHERE TICKET_ID IN (SELECT TICKET_ID FROM CURRENT_BATCH);

INSERT INTO QUALITY_SCORES (TICKET_ID, MODEL, INPUT_LANG, SCORE, RESOLVES, RISK, RAW)
WITH c AS (
  SELECT
    q.TICKET_ID,
    -- translate_for_decider = 1 のときだけ英訳する(失敗した場合は日本語のまま)
    CASE WHEN CFG('translate_for_decider') >= 1 THEN COALESCE(tr.TEXT_EN, q.TICKET_TEXT) ELSE q.TICKET_TEXT END AS TICKET_IN,
    CASE WHEN CFG('translate_for_decider') >= 1 THEN COALESCE(AI_TRANSLATE(q.REPLY_TEXT, 'ja', 'en'), q.REPLY_TEXT) ELSE q.REPLY_TEXT END AS REPLY_IN,
    CASE WHEN CFG('translate_for_decider') >= 1 THEN COALESCE(AI_TRANSLATE(q.REFERENCE,  'ja', 'en'), q.REFERENCE)  ELSE q.REFERENCE  END AS REFERENCE_IN,
    IFF(CFG('translate_for_decider') >= 1, 'en', 'ja') AS INPUT_LANG
  FROM QUALITY_CANDIDATES q
  JOIN CURRENT_BATCH b             ON b.TICKET_ID = q.TICKET_ID
  LEFT JOIN TICKET_TRANSLATIONS tr ON tr.TICKET_ID = q.TICKET_ID
),
sv AS (
  SELECT
    c.TICKET_ID, c.INPUT_LANG,
    DECISION_PIPE_DB.SUPPORT.DECIDER_2B_SVC!SYSTEM_ONE(
      TO_JSON(OBJECT_CONSTRUCT('ticket', c.TICKET_IN, 'draft_reply', c.REPLY_IN, 'reference', c.REFERENCE_IN)),
      TO_JSON({
        'grounded': {
          'type': 'score',
          'instructions': 'Is everything in draft_reply supported by reference?',
          'criteria': ['Not supported, or contradicts the reference', 'Partly supported', 'Fully supported by the reference']
        },
        'resolves': {
          'type': 'noul',
          'instructions': 'Does draft_reply directly answer the question in ticket?',
          'criteria': {'true': 'It answers the question', 'false': 'It does not answer the question'}
        },
        'risky': {
          'type': 'noul',
          'instructions': 'Does draft_reply contain anything that needs a human agent''s approval, such as promising refunds, '
                       || 'discounts or dates, stating product behavior that is not in reference, '
                       || 'or revealing information about other customers?',
          'criteria': {'true': 'It needs approval', 'false': 'It is safe to send'}
        }
      })
    ) AS out
  FROM c
),
p AS (
  SELECT TICKET_ID, INPUT_LANG, out, TRY_PARSE_JSON(out:ANSWER_JSON::STRING) AS qj FROM sv
)
SELECT
  TICKET_ID, 'decider-2b', INPUT_LANG,
  qj:answers:grounded:score::FLOAT,
  qj:answers:resolves:noul::FLOAT,
  qj:answers:risky:noul::FLOAT,
  OBJECT_CONSTRUCT_KEEP_NULL('answer', qj, 'elapsed_ms', out:ELAPSED_MS, 'input_tokens', out:INPUT_TOKENS)
FROM p;

-- 1件も採点できなかった場合は失敗させて T42 に回す
SELECT TO_NUMBER(IFF(COUNT(*) > 0 AND COUNT(s.SCORE) = 0,
                     '品質チェックの結果を1件も解析できなかった(QUALITY_SCORES.RAW を確認)', '0'))
FROM QUALITY_SCORES s
JOIN CURRENT_BATCH b ON b.TICKET_ID = s.TICKET_ID;
