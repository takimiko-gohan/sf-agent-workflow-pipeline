-- =====================================================================
-- T00_PICK_BATCH  [SQL(カードに貼り付け)/ ルート]
-- 次の受付日のチケットを CURRENT_BATCH に取り出し、戻り値で後続を切り替える。
--   戻り値: HAS_TICKETS / NO_TICKETS
--   グラフの Config (JSON) の batch_mode を読む('daily' = 1日ずつ / 'all' = 未処理日をまとめて)
-- 戻り値を計算して設定するため、タスク本体を Snowflake Scripting のブロックにしている
-- (公式ドキュメントの SYSTEM$SET_RETURN_VALUE の例3と同じ形)。
--
-- Pipeline Builder の設定
--   種類                  : SQL(このブロックをそのまま Source に貼り付け)
--   Predecessors          : なし(ルートタスク)
-- =====================================================================
DECLARE
  bmode VARCHAR DEFAULT 'daily';
  n     NUMBER DEFAULT 0;
  dates VARCHAR;
  rv    VARCHAR;
BEGIN
  USE SCHEMA DECISION_PIPE_DB.SUPPORT;

  BEGIN
    SELECT COALESCE(TRIM(SYSTEM$GET_TASK_GRAPH_CONFIG('batch_mode')::VARCHAR, '"'), 'daily') INTO :bmode;
  EXCEPTION
    WHEN OTHER THEN bmode := 'daily';
  END;

  TRUNCATE TABLE CURRENT_BATCH_DATES;
  TRUNCATE TABLE CURRENT_BATCH;

  IF (bmode = 'all') THEN
    INSERT INTO CURRENT_BATCH_DATES
    SELECT c.RECEIVED_DATE FROM BATCH_CALENDAR c
    WHERE NOT EXISTS (SELECT 1 FROM BATCH_STATE s WHERE s.RECEIVED_DATE = c.RECEIVED_DATE);
  ELSE
    INSERT INTO CURRENT_BATCH_DATES
    SELECT MIN(c.RECEIVED_DATE) FROM BATCH_CALENDAR c
    WHERE NOT EXISTS (SELECT 1 FROM BATCH_STATE s WHERE s.RECEIVED_DATE = c.RECEIVED_DATE)
    HAVING MIN(c.RECEIVED_DATE) IS NOT NULL;
  END IF;

  INSERT INTO CURRENT_BATCH (TICKET_ID, RECEIVED_DATE)
  SELECT t.TICKET_ID, t.RECEIVED_AT::DATE
  FROM SUPPORT_TICKETS t
  JOIN CURRENT_BATCH_DATES d ON d.RECEIVED_DATE = t.RECEIVED_AT::DATE;
  n := SQLROWCOUNT;

  SELECT LISTAGG(TO_VARCHAR(RECEIVED_DATE, 'YYYY-MM-DD'), ',') WITHIN GROUP (ORDER BY RECEIVED_DATE)
    INTO :dates
  FROM CURRENT_BATCH_DATES;

  rv := IFF(n > 0, 'HAS_TICKETS', 'NO_TICKETS');
  CALL SYSTEM$SET_RETURN_VALUE(:rv);

  RETURN rv || ' mode=' || bmode || ' dates=' || COALESCE(dates, '(なし: 全日処理済み)') || ' tickets=' || n;
END;
