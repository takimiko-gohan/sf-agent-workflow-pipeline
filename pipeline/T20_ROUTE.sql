-- =====================================================================
-- T20_ROUTE  [SQL(カードに貼り付け)]
-- 分類結果をもとに振り分け、戻り値で後続を切り替える。
--   human : 担当者が必要(または分類できなかった)
--   auto  : ヘルプ記事が確信度高く特定でき、顧客データが不要 → T40 で定型回答
--   agent : それ以外 → T30 でエージェント(受付順に優先度を付ける)
--   戻り値: ALL_AUTO(agent なし)/ AGENT(上限以内)/ AGENT_OVERFLOW(上限超過)
--
-- Pipeline Builder の設定
--   種類                  : SQL(このブロックをそのまま Source に貼り付け)
--   Predecessors          : T10_CLASSIFY, T11_CLASSIFY_FALLBACK
--   Condition(WHEN)      : SYSTEM$PREDECESSORS_STATE('AT_LEAST_ONE_SUCCEEDED')
-- =====================================================================
DECLARE
  n_total  NUMBER DEFAULT 0;
  n_auto   NUMBER DEFAULT 0;
  n_agent  NUMBER DEFAULT 0;
  n_human  NUMBER DEFAULT 0;
  max_rows FLOAT;
  rv       VARCHAR;
BEGIN
  USE SCHEMA DECISION_PIPE_DB.SUPPORT;

  DELETE FROM ROUTED_TICKETS WHERE TICKET_ID IN (SELECT TICKET_ID FROM CURRENT_BATCH);

  INSERT INTO ROUTED_TICKETS
    (TICKET_ID, TICKET_TEXT, RECEIVED_AT, CATEGORY, KB_ID, KB_CONF, HUMAN_PROB, ACCOUNT_DATA_PROB, ROUTE, AGENT_PRIORITY)
  WITH r AS (
    SELECT
      t.TICKET_ID, t.TICKET_TEXT, t.RECEIVED_AT,
      c.CATEGORY, c.KB_ID, c.KB_CONF, c.HUMAN_PROB, c.ACCOUNT_DATA_PROB,
      CASE
        WHEN c.CATEGORY IS NULL OR c.HUMAN_PROB IS NULL THEN 'human'    -- 分類できないものは安全側へ
        WHEN c.HUMAN_PROB >= CFG('human_min') THEN 'human'
        WHEN k.KB_ID IS NOT NULL
         AND c.KB_CONF >= CFG('auto_conf_min')
         AND c.ACCOUNT_DATA_PROB < CFG('auto_data_max') THEN 'auto'
        ELSE 'agent'
      END AS ROUTE
    FROM SUPPORT_TICKETS t
    JOIN CURRENT_BATCH b         ON b.TICKET_ID = t.TICKET_ID
    LEFT JOIN CLASSIFY_RESULTS c ON c.TICKET_ID = t.TICKET_ID
    LEFT JOIN KB_ARTICLES k      ON k.KB_ID = c.KB_ID
  )
  SELECT r.*,
         IFF(ROUTE = 'agent',
             ROW_NUMBER() OVER (PARTITION BY ROUTE ORDER BY RECEIVED_AT, TICKET_ID),   -- 受付順
             NULL)
  FROM r;

  SELECT COUNT(*), COUNT_IF(r.ROUTE = 'auto'), COUNT_IF(r.ROUTE = 'agent'), COUNT_IF(r.ROUTE = 'human')
    INTO :n_total, :n_auto, :n_agent, :n_human
  FROM ROUTED_TICKETS r JOIN CURRENT_BATCH b ON b.TICKET_ID = r.TICKET_ID;
  SELECT CFG('agent_max_rows') INTO :max_rows;

  rv := CASE WHEN n_agent = 0 THEN 'ALL_AUTO'
             WHEN n_agent <= max_rows THEN 'AGENT'
             ELSE 'AGENT_OVERFLOW' END;
  CALL SYSTEM$SET_RETURN_VALUE(:rv);

  RETURN rv || ' total=' || n_total || ' auto=' || n_auto || ' agent=' || n_agent
            || ' human=' || n_human || ' max=' || max_rows;
END;
