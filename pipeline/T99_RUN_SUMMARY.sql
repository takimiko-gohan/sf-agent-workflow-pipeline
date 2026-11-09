-- =====================================================================
-- T99_RUN_SUMMARY  [ファイナライザー]
-- 途中で失敗しても必ず動く。通った経路・サマリを記録し、完了した受付日を処理済みにする
--
-- Pipeline Builder の設定(Task タブ > Dependencies)
--   Predecessors          : なし(グラフのファイナライザーに設定)
--   Predecessors condition: 設定不可
--   Additional conditions : -
-- =====================================================================
CALL DECISION_PIPE_DB.SUPPORT.SP_RUN_SUMMARY();
