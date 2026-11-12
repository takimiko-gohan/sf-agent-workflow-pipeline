-- =====================================================================
-- T40_AUTO_ANSWER  [.sql ファイル]
-- (1) ROUTE = 'auto' のチケットに、選ばれたヘルプ記事だけを根拠にした定型回答を生成する
-- (2) 送信候補(定型回答 + エージェントの回答済み案)と、照合に使う参照情報を QUALITY_CANDIDATES にまとめる
-- モデル名 'claude-sonnet-5' は自アカウントで AI_COMPLETE に使えるものに置き換える。
-- 生成に失敗した行は REPLY_TEXT が NULL になり、T45 で auto_failed として担当者に回る。
--
-- Pipeline Builder の設定
--   種類                  : SQL file(このファイル)
--   Predecessors          : T20_ROUTE, T30_AGENT_ANSWER, T31_OVERFLOW_TO_HUMAN, T35_AGENT_FAILED
--   Condition(WHEN)      : SYSTEM$PREDECESSORS_STATE('AT_LEAST_ONE_SUCCEEDED')
--                           (T30 が失敗して T35 が動いた場合や、T30・T31 がスキップされた場合も進める)
-- =====================================================================
USE SCHEMA DECISION_PIPE_DB.SUPPORT;

-- (1) 定型回答
DELETE FROM AUTO_ANSWERS WHERE TICKET_ID IN (SELECT TICKET_ID FROM CURRENT_BATCH);

INSERT INTO AUTO_ANSWERS (TICKET_ID, KB_ID, REPLY_TEXT, MODEL)
SELECT
  r.TICKET_ID, r.KB_ID,
  AI_COMPLETE(
    'claude-sonnet-5',
    'あなたはプロジェクト管理SaaS「TaskFlow」のサポート担当です。次のヘルプ記事の内容だけを根拠に、問い合わせへの返信文を日本語の丁寧語で作成してください。'
    || '記事に書かれていないこと(返金、個別の契約内容、日付の約束など)は書かないでください。'
    || '冒頭は「(会社名) ご担当者様」、末尾は「TaskFlowサポート」とし、返信文だけを出力してください。\n'
    || '\nヘルプ記事(' || k.KB_ID || ' ' || k.TITLE || '):\n' || k.BODY
    || '\n\n問い合わせ:\n' || r.TICKET_TEXT),
  'claude-sonnet-5'
FROM ROUTED_TICKETS r
JOIN CURRENT_BATCH b ON b.TICKET_ID = r.TICKET_ID
JOIN KB_ARTICLES k   ON k.KB_ID = r.KB_ID
WHERE r.ROUTE = 'auto';

-- (2) 送信候補と参照情報
DELETE FROM QUALITY_CANDIDATES WHERE TICKET_ID IN (SELECT TICKET_ID FROM CURRENT_BATCH);

INSERT INTO QUALITY_CANDIDATES (TICKET_ID, SRC, TICKET_TEXT, REPLY_TEXT, REFERENCE)
WITH src AS (
  SELECT ar.TICKET_ID, f.value::STRING AS KB_ID
  FROM AGENT_RESULTS ar, LATERAL FLATTEN(INPUT => ar.SOURCES) f
  WHERE ar.TICKET_ID IN (SELECT TICKET_ID FROM CURRENT_BATCH)
),
ref AS (
  SELECT s.TICKET_ID, LISTAGG(k.KB_ID || ' ' || k.TITLE || ': ' || k.BODY, '\n') AS KB_REF
  FROM src s JOIN KB_ARTICLES k ON k.KB_ID = s.KB_ID
  GROUP BY s.TICKET_ID
)
SELECT r.TICKET_ID, 'auto', r.TICKET_TEXT, a.REPLY_TEXT,
       'ヘルプ記事 ' || k.KB_ID || ' ' || k.TITLE || ': ' || k.BODY
FROM ROUTED_TICKETS r
JOIN CURRENT_BATCH b ON b.TICKET_ID = r.TICKET_ID
JOIN AUTO_ANSWERS a  ON a.TICKET_ID = r.TICKET_ID
JOIN KB_ARTICLES k   ON k.KB_ID = a.KB_ID
WHERE r.ROUTE = 'auto' AND a.REPLY_TEXT IS NOT NULL
UNION ALL
SELECT r.TICKET_ID, 'agent', r.TICKET_TEXT, ar.REPLY_TEXT,
       'ヘルプ記事: ' || COALESCE(ref.KB_REF, '(なし)') || '\n顧客データ: ' || COALESCE(ar.FACTS, '(なし)')
FROM ROUTED_TICKETS r
JOIN CURRENT_BATCH b  ON b.TICKET_ID = r.TICKET_ID
JOIN AGENT_RESULTS ar ON ar.TICKET_ID = r.TICKET_ID
LEFT JOIN ref         ON ref.TICKET_ID = r.TICKET_ID
WHERE r.ROUTE = 'agent' AND ar.STATUS = 'ok' AND ar.RESOLUTION = 'answered'
  AND ar.REPLY_TEXT IS NOT NULL AND ar.REPLY_TEXT <> '';
