-- =====================================================================
-- T31_OVERFLOW_TO_HUMAN  [SQL(カードに貼り付け)]
-- エージェントの上限(agent_max_rows)を超えた分を担当者キューへ。T30 と並列に動く。
--
-- Pipeline Builder の設定
--   種類                  : SQL
--   Predecessors          : T20_ROUTE
--   Condition(WHEN)      : SYSTEM$GET_PREDECESSOR_RETURN_VALUE('T20_ROUTE') = 'AGENT_OVERFLOW'
-- =====================================================================
MERGE INTO DECISION_PIPE_DB.SUPPORT.HUMAN_REVIEW_QUEUE q
USING (
  SELECT r.TICKET_ID, r.TICKET_TEXT
  FROM DECISION_PIPE_DB.SUPPORT.ROUTED_TICKETS r
  JOIN DECISION_PIPE_DB.SUPPORT.CURRENT_BATCH b ON b.TICKET_ID = r.TICKET_ID
  WHERE r.ROUTE = 'agent'
    AND r.AGENT_PRIORITY > DECISION_PIPE_DB.SUPPORT.CFG('agent_max_rows')
) s ON q.TICKET_ID = s.TICKET_ID
WHEN NOT MATCHED THEN INSERT (TICKET_ID, REASON, SOURCE_TASK, TICKET_TEXT)
  VALUES (s.TICKET_ID, 'overflow', 'T31_OVERFLOW_TO_HUMAN', s.TICKET_TEXT);
