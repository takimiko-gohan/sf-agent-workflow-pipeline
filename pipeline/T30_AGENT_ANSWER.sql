-- =====================================================================
-- T30_AGENT_ANSWER  [通常]
-- 受付順に agent_max_rows 件まで、エージェントがヘルプ記事と顧客データを調べて回答案を作る。タイムアウトは件数×120秒程度
--
-- Pipeline Builder の設定(Task タブ > Dependencies)
--   Predecessors          : T20_ROUTE
--   Predecessors condition: All succeeded(既定)
--   Additional conditions : SYSTEM$GET_PREDECESSOR_RETURN_VALUE('T20_ROUTE') <> 'ALL_AUTO'
-- =====================================================================
CALL DECISION_PIPE_DB.SUPPORT.SP_RUN_AGENT_BATCH();
