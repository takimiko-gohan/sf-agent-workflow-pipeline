-- =====================================================================
-- T50_HUMAN_QUEUE  [.sql ファイル]
-- 担当者行きのチケットがあるときだけ動く。キューに入れ、担当者向けの引き継ぎメモを生成する。
-- 同じチケットは1回だけ投入する(T31・T35 で先に入った理由を残し、下書きは後から補う)。
-- モデル名 'claude-sonnet-5' は自アカウントで AI_COMPLETE に使えるものに置き換える。
--
-- Pipeline Builder の設定
--   種類                  : SQL file(このファイル)
--   Predecessors          : T45_FINALIZE
--   Condition(WHEN)      : SYSTEM$GET_PREDECESSOR_RETURN_VALUE('T45_FINALIZE') = 'REVIEW_NEEDED'
-- =====================================================================
USE SCHEMA DECISION_PIPE_DB.SUPPORT;

MERGE INTO HUMAN_REVIEW_QUEUE q
USING (
  SELECT f.TICKET_ID, f.HUMAN_REASON, f.DRAFT_REPLY, t.TICKET_TEXT
  FROM FINAL_RESULTS f
  JOIN CURRENT_BATCH b   ON b.TICKET_ID = f.TICKET_ID
  JOIN SUPPORT_TICKETS t ON t.TICKET_ID = f.TICKET_ID
  WHERE f.FINAL_ROUTE = 'human'
) s ON q.TICKET_ID = s.TICKET_ID
WHEN MATCHED THEN UPDATE SET DRAFT_REPLY = COALESCE(q.DRAFT_REPLY, s.DRAFT_REPLY)
WHEN NOT MATCHED THEN INSERT (TICKET_ID, REASON, SOURCE_TASK, TICKET_TEXT, DRAFT_REPLY)
  VALUES (s.TICKET_ID, s.HUMAN_REASON, 'T50_HUMAN_QUEUE', s.TICKET_TEXT, s.DRAFT_REPLY);

-- 担当者向けの引き継ぎメモ
UPDATE HUMAN_REVIEW_QUEUE q
   SET HANDOFF_NOTE = AI_COMPLETE(
         'claude-sonnet-5',
         'あなたはSaaSのサポートチームのリーダーです。次の問い合わせを担当者に引き継ぐためのメモを日本語で作成してください。'
         || '「要点」「顧客の要望」「確認・判断が必要な事項」「一次返信の方針」の4項目で、各1〜2行の箇条書きにしてください。'
         || '事実として書けるのは問い合わせと下書きに書かれていることだけです。\n'
         || '\n引き継ぎ理由: ' || q.REASON
         || '\n問い合わせ:\n' || q.TICKET_TEXT
         || '\n下書き(あれば):\n' || COALESCE(q.DRAFT_REPLY, 'なし'))
 WHERE q.HANDOFF_NOTE IS NULL
   AND q.TICKET_ID IN (SELECT TICKET_ID FROM CURRENT_BATCH);

-- 通知を送る場合は通知統合を作成し、下のコメントを外す
-- CALL SYSTEM$SEND_SNOWFLAKE_NOTIFICATION(
--   SNOWFLAKE.NOTIFICATION.TEXT_PLAIN('担当者の対応が必要な問い合わせがあります'),
--   SNOWFLAKE.NOTIFICATION.INTEGRATION('<email_integration_name>'));
