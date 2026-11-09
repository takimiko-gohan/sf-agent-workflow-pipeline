-- =====================================================================
-- T20_ROUTE  [通常]
-- 戻り値: ALL_AUTO / AGENT / AGENT_OVERFLOW
--
-- Pipeline Builder の設定(Task タブ > Dependencies)
--   Predecessors          : T10_DECIDE, T11_DECIDE_FALLBACK
--   Predecessors condition: At least one succeeded
--   Additional conditions : -
-- =====================================================================
CALL DECISION_PIPE_DB.DEMO.SP_ROUTE();
