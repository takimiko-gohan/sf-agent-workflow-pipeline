-- =====================================================================
-- T11_CLASSIFY_FALLBACK  [通常]
-- T10 が失敗したときだけ動く(完了状態による分岐)
--
-- Pipeline Builder の設定(Task タブ > Dependencies)
--   Predecessors          : T10_CLASSIFY
--   Predecessors condition: All failed
--   Additional conditions : -
-- =====================================================================
CALL DECISION_PIPE_DB.SUPPORT.SP_CLASSIFY('llm');
