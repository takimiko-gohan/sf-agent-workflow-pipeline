-- =====================================================================
-- T05_NO_TICKETS  [SQL(カードに貼り付け)]
-- チケットがない日だけ動く(戻り値による分岐)。空振りをイベントログに残す。
--
-- Pipeline Builder の設定
--   種類                  : SQL
--   Predecessors          : T00_PICK_BATCH
--   Condition(WHEN)      : SYSTEM$GET_PREDECESSOR_RETURN_VALUE('T00_PICK_BATCH') = 'NO_TICKETS'
-- =====================================================================
INSERT INTO DECISION_PIPE_DB.SUPPORT.PIPELINE_EVENTS (RUN_GROUP_ID, TASK, EVENT, DETAIL)
SELECT SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_GRAPH_RUN_GROUP_ID'), 'T05_NO_TICKETS', 'no_tickets', '処理対象のチケットなし';
