-- =====================================================================
-- T05_NO_TICKETS  [通常]
-- チケットがない日だけ動く(戻り値による分岐)
--
-- Pipeline Builder の設定(Task タブ > Dependencies)
--   Predecessors          : T00_PICK_BATCH
--   Predecessors condition: All succeeded(既定)
--   Additional conditions : SYSTEM$GET_PREDECESSOR_RETURN_VALUE('T00_PICK_BATCH') = 'NO_TICKETS'
-- =====================================================================
CALL DECISION_PIPE_DB.SUPPORT.SP_LOG_EVENT('T05_NO_TICKETS', 'no_tickets', '処理対象のチケットなし');
