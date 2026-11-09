-- =====================================================================
-- T20_ROUTE  [通常]
-- auto / agent / human に振り分け。戻り値: ALL_AUTO / AGENT / AGENT_OVERFLOW
--
-- Pipeline Builder の設定(Task タブ > Dependencies)
--   Predecessors          : T10_CLASSIFY, T11_CLASSIFY_FALLBACK
--   Predecessors condition: At least one succeeded
--   Additional conditions : -
-- =====================================================================
CALL DECISION_PIPE_DB.SUPPORT.SP_ROUTE();
