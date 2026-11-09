-- =====================================================================
-- T40_FINALIZE_RESULTS  [通常]
-- 戻り値: REVIEW_NEEDED / OK。品質チェックは decision→失敗時LLM に内部で切替
--
-- Pipeline Builder の設定(Task タブ > Dependencies)
--   Predecessors          : T20_ROUTE, T30_AGENT_INVESTIGATE, T31_OVERFLOW_TO_HUMAN, T35_AGENT_FAILED
--   Predecessors condition: At least one succeeded
--   Additional conditions : -
-- =====================================================================
CALL DECISION_PIPE_DB.DEMO.SP_FINALIZE_RESULTS();
