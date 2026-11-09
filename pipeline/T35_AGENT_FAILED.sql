-- =====================================================================
-- T35_AGENT_FAILED  [通常]
-- T30 が失敗したときだけ、エージェント対象を担当者キューへ退避
--
-- Pipeline Builder の設定(Task タブ > Dependencies)
--   Predecessors          : T30_AGENT_ANSWER
--   Predecessors condition: All failed
--   Additional conditions : -
-- =====================================================================
CALL DECISION_PIPE_DB.SUPPORT.SP_ENQUEUE_REVIEW('agent_failed');
