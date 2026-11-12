-- =====================================================================
-- T35_AGENT_FAILED  [SQL(カードに貼り付け)]
-- T30(エージェント)が失敗したときだけ、エージェント対象のチケットを担当者キューへ退避する。
--
-- Pipeline Builder の設定
--   種類                  : SQL
--   Predecessors          : T30_AGENT_ANSWER
--   Condition(WHEN)      : SYSTEM$PREDECESSORS_STATE('ALL_FAILED')
-- =====================================================================
MERGE INTO DECISION_PIPE_DB.SUPPORT.HUMAN_REVIEW_QUEUE q
USING (
  SELECT r.TICKET_ID, r.TICKET_TEXT
  FROM DECISION_PIPE_DB.SUPPORT.ROUTED_TICKETS r
  JOIN DECISION_PIPE_DB.SUPPORT.CURRENT_BATCH b ON b.TICKET_ID = r.TICKET_ID
  WHERE r.ROUTE = 'agent'
) s ON q.TICKET_ID = s.TICKET_ID
WHEN NOT MATCHED THEN INSERT (TICKET_ID, REASON, SOURCE_TASK, TICKET_TEXT)
  VALUES (s.TICKET_ID, 'agent_failed', 'T35_AGENT_FAILED', s.TICKET_TEXT);
