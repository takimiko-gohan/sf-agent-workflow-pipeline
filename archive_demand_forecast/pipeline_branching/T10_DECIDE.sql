-- =====================================================================
-- T10_DECIDE  [通常]
-- snowflake-decision で判定。未有効化・強制失敗・全件解析不能ならタスクが失敗する
--
-- Pipeline Builder の設定(Task タブ > Dependencies)
--   Predecessors          : T00_PICK_BATCH
--   Predecessors condition: All succeeded(既定)
--   Additional conditions : SYSTEM$GET_PREDECESSOR_RETURN_VALUE('T00_PICK_BATCH') = 'HAS_ALERTS'
-- =====================================================================
CALL DECISION_PIPE_DB.DEMO.SP_DECIDE('decision');
