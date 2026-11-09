-- =====================================================================
-- T11_DECIDE_FALLBACK  [通常]
-- T10 が失敗したときだけ動く(完了状態による分岐)
--
-- Pipeline Builder の設定(Task タブ > Dependencies)
--   Predecessors          : T10_DECIDE
--   Predecessors condition: All failed
--   Additional conditions : -
-- =====================================================================
CALL DECISION_PIPE_DB.DEMO.SP_DECIDE('llm');
