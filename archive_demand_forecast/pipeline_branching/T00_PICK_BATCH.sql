-- =====================================================================
-- T00_PICK_BATCH  [ルート]
-- 戻り値: HAS_ALERTS / NO_ALERTS。グラフ Config の batch_mode を読む
--
-- Pipeline Builder の設定(Task タブ > Dependencies)
--   Predecessors          : なし(ルートタスク)
--   Predecessors condition: -
--   Additional conditions : -
-- =====================================================================
CALL DECISION_PIPE_DB.DEMO.SP_PICK_BATCH();
