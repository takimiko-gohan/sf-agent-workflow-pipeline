-- =====================================================================
-- T45_FINALIZE  [SQL(カードに貼り付け)]
-- 品質チェックの結果で送信可 / 担当者行きを確定し、戻り値で後続を切り替える。
--   送信可の基準: 根拠スコア >= quality_min かつ resolves >= resolves_min かつ risky < risk_max
--   基準を満たさないものは、下書きを付けて human にする
--   戻り値: REVIEW_NEEDED(human あり)/ OK
--
-- Pipeline Builder の設定
--   種類                  : SQL(このブロックをそのまま Source に貼り付け)
--   Predecessors          : T41_QUALITY_CHECK, T42_QUALITY_FALLBACK
--   Condition(WHEN)      : SYSTEM$PREDECESSORS_STATE('AT_LEAST_ONE_SUCCEEDED')
-- =====================================================================
DECLARE
  n_total NUMBER DEFAULT 0;
  n_human NUMBER DEFAULT 0;
  n_send  NUMBER DEFAULT 0;
  rv      VARCHAR;
BEGIN
  USE SCHEMA DECISION_PIPE_DB.SUPPORT;

  DELETE FROM FINAL_RESULTS WHERE TICKET_ID IN (SELECT TICKET_ID FROM CURRENT_BATCH);

  INSERT INTO FINAL_RESULTS
    (TICKET_ID, ROUTE, FINAL_ROUTE, FINAL_CATEGORY, FINAL_REPLY, DRAFT_REPLY,
     QUALITY_SCORE, RESOLVES_PROB, RISK_PROB, QUALITY_RAW, HUMAN_REASON, QUALITY_MODEL)
  WITH x AS (
    SELECT
      r.TICKET_ID, r.ROUTE, r.CATEGORY, r.AGENT_PRIORITY,
      c.REPLY_TEXT                                      AS cand_reply,
      COALESCE(a.REPLY_TEXT, NULLIF(ar.REPLY_TEXT, '')) AS draft,
      ar.TICKET_ID                                      AS ar_tid,
      ar.STATUS                                         AS ar_status,
      ar.RESOLUTION                                     AS ar_res,
      q.MODEL, q.SCORE, q.RESOLVES, q.RISK, q.RAW,
      COALESCE(c.TICKET_ID IS NOT NULL
               AND q.SCORE    >= CFG('quality_min')
               AND q.RESOLVES >= CFG('resolves_min')
               AND q.RISK     <  CFG('risk_max'), FALSE) AS accepted
    FROM ROUTED_TICKETS r
    JOIN CURRENT_BATCH b            ON b.TICKET_ID = r.TICKET_ID
    LEFT JOIN AUTO_ANSWERS a        ON a.TICKET_ID = r.TICKET_ID AND r.ROUTE = 'auto'
    LEFT JOIN AGENT_RESULTS ar      ON ar.TICKET_ID = r.TICKET_ID AND r.ROUTE = 'agent'
    LEFT JOIN QUALITY_CANDIDATES c  ON c.TICKET_ID = r.TICKET_ID
    LEFT JOIN QUALITY_SCORES q      ON q.TICKET_ID = r.TICKET_ID
  )
  SELECT
    TICKET_ID,
    ROUTE,
    IFF(accepted, ROUTE, 'human'),
    CATEGORY,
    IFF(accepted, cand_reply, NULL),
    IFF(accepted, NULL, draft),
    SCORE, RESOLVES, RISK, RAW,
    CASE
      WHEN accepted                                                  THEN NULL
      WHEN ROUTE = 'human'                                           THEN 'classified_human'
      WHEN ROUTE = 'auto'  AND draft IS NULL                         THEN 'auto_failed'
      WHEN ROUTE = 'agent' AND AGENT_PRIORITY > CFG('agent_max_rows') THEN 'overflow'
      WHEN ROUTE = 'agent' AND ar_tid IS NULL                        THEN 'agent_not_run'
      WHEN ROUTE = 'agent' AND ar_status = 'error'                   THEN 'agent_error'
      WHEN ROUTE = 'agent' AND ar_res = 'needs_human'                THEN 'agent_escalated'
      WHEN ROUTE = 'agent' AND (ar_res IS NULL OR draft IS NULL)     THEN 'agent_unparsed'
      WHEN RISK >= CFG('risk_max')                                   THEN 'risky_reply'
      WHEN RESOLVES < CFG('resolves_min')                            THEN 'not_resolved'
      ELSE 'low_quality'
    END,
    IFF(ROUTE IN ('auto', 'agent'), MODEL, NULL)
  FROM x;

  SELECT COUNT(*), COUNT_IF(f.FINAL_ROUTE = 'human'), COUNT_IF(f.FINAL_ROUTE IN ('auto', 'agent'))
    INTO :n_total, :n_human, :n_send
  FROM FINAL_RESULTS f JOIN CURRENT_BATCH b ON b.TICKET_ID = f.TICKET_ID;

  rv := IFF(n_human > 0, 'REVIEW_NEEDED', 'OK');
  CALL SYSTEM$SET_RETURN_VALUE(:rv);

  RETURN rv || ' total=' || n_total || ' send=' || n_send || ' human=' || n_human;
END;
