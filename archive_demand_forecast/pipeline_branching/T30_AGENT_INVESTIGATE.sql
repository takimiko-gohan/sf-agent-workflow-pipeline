-- =====================================================================
-- T30_AGENT_INVESTIGATE  [通常]
-- 優先度上位 agent_max_rows 件をエージェントで調査。タイムアウトは件数×90秒程度
--
-- Pipeline Builder の設定(Task タブ > Dependencies)
--   Predecessors          : T20_ROUTE
--   Predecessors condition: All succeeded(既定)
--   Additional conditions : SYSTEM$GET_PREDECESSOR_RETURN_VALUE('T20_ROUTE') <> 'ALL_AUTO'
-- =====================================================================
CALL DECISION_PIPE_DB.DEMO.SP_RUN_AGENT_BATCH();
