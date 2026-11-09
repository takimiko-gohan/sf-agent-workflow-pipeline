-- =====================================================================
-- T00_PICK_BATCH  [ルート]
-- 次の受付日のチケットを取り出す。戻り値: HAS_TICKETS / NO_TICKETS。グラフ Config の batch_mode を読む
--
-- Pipeline Builder の設定(Task タブ > Dependencies)
--   Predecessors          : なし(ルートタスク)
--   Predecessors condition: -
--   Additional conditions : -
-- =====================================================================
CALL DECISION_PIPE_DB.SUPPORT.SP_PICK_BATCH();
