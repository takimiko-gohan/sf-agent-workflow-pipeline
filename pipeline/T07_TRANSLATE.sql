-- =====================================================================
-- T07_TRANSLATE  [.sql ファイル]
-- decider-2b(英語モデル)に渡すため、AI_TRANSLATE で英訳する。
--   (1) ヘルプ記事タイトルのうち未翻訳のものを英訳して KB_TRANSLATIONS に蓄積(decider-2b の選択肢)
--   (2) 今回のバッチの問い合わせを英訳して TICKET_TRANSLATIONS に保存
-- 翻訳に失敗した行は TEXT_EN が NULL になる(AI_TRANSLATE は失敗行に NULL を返す)。
-- このタスクが失敗しても、T10 は日本語のまま分類を続ける(T10 の条件で ALL_DONE を使っている)。
-- translate_for_decider = 0 のときは何もしない(日本語のまま渡した場合と比べる用)。
--
-- Pipeline Builder の設定
--   種類                  : SQL file(このファイル)
--   Predecessors          : T00_PICK_BATCH
--   Condition(WHEN)      : SYSTEM$GET_PREDECESSOR_RETURN_VALUE('T00_PICK_BATCH') = 'HAS_TICKETS'
-- =====================================================================
USE SCHEMA DECISION_PIPE_DB.SUPPORT;

-- (1) ヘルプ記事タイトル(未翻訳・翻訳失敗のものだけ)
DELETE FROM KB_TRANSLATIONS WHERE TITLE_EN IS NULL;

INSERT INTO KB_TRANSLATIONS (KB_ID, TITLE_EN)
SELECT k.KB_ID, AI_TRANSLATE(k.TITLE, 'ja', 'en')
FROM KB_ARTICLES k
WHERE CFG('translate_for_decider') >= 1
  AND NOT EXISTS (SELECT 1 FROM KB_TRANSLATIONS x WHERE x.KB_ID = k.KB_ID);

-- (2) 問い合わせ(エラー詳細も残す)
DELETE FROM TICKET_TRANSLATIONS WHERE TICKET_ID IN (SELECT TICKET_ID FROM CURRENT_BATCH);

INSERT INTO TICKET_TRANSLATIONS (TICKET_ID, TEXT_EN, ERROR_MESSAGE)
SELECT TICKET_ID, r:value::STRING, r:error::STRING
FROM (
  SELECT t.TICKET_ID, AI_TRANSLATE(t.TICKET_TEXT, 'ja', 'en', TRUE) AS r
  FROM SUPPORT_TICKETS t
  JOIN CURRENT_BATCH b ON b.TICKET_ID = t.TICKET_ID
  WHERE CFG('translate_for_decider') >= 1
) x;

-- (3) 結果をイベントログへ
INSERT INTO PIPELINE_EVENTS (RUN_GROUP_ID, TASK, EVENT, DETAIL)
SELECT
  ANY_VALUE(SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_GRAPH_RUN_GROUP_ID')),
  'T07_TRANSLATE',
  IFF(ANY_VALUE(CFG('translate_for_decider')) >= 1, 'translated', 'skipped'),
  'tickets ok=' || COUNT_IF(tr.TEXT_EN IS NOT NULL) || ' error=' || COUNT_IF(tr.TEXT_EN IS NULL AND tr.TICKET_ID IS NOT NULL)
    || ' (translate_for_decider=' || ANY_VALUE(CFG('translate_for_decider')) || ')'
FROM CURRENT_BATCH b
LEFT JOIN TICKET_TRANSLATIONS tr ON tr.TICKET_ID = b.TICKET_ID;
