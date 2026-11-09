-- =====================================================================
-- T10_CLASSIFY  [通常]
-- snowflake-decision で分類(種類・ヘルプ記事・要担当者・要顧客データ)。未有効化・強制失敗・全件解析不能なら失敗
--
-- Pipeline Builder の設定(Task タブ > Dependencies)
--   Predecessors          : T00_PICK_BATCH
--   Predecessors condition: All succeeded(既定)
--   Additional conditions : SYSTEM$GET_PREDECESSOR_RETURN_VALUE('T00_PICK_BATCH') = 'HAS_TICKETS'
-- =====================================================================
CALL DECISION_PIPE_DB.SUPPORT.SP_CLASSIFY('decision');
