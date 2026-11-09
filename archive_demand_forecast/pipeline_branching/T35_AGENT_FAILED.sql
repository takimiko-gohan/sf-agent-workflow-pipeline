-- =====================================================================
-- T35_AGENT_FAILED  [通常]
-- T30 が失敗したときだけ、エージェント対象を人手キューへ退避
--
-- Pipeline Builder の設定(Task タブ > Dependencies)
--   Predecessors          : T30_AGENT_INVESTIGATE
--   Predecessors condition: All failed
--   Additional conditions : -
-- =====================================================================
CALL DECISION_PIPE_DB.DEMO.SP_ENQUEUE_REVIEW('agent_failed');
