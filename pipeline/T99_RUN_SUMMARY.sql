-- =====================================================================
-- T99_RUN_SUMMARY  [.sql ファイル / ファイナライザー]
-- 途中のタスクが失敗しても必ず動く。
--   (1) 実行サマリ(正解ラベルとの突合)を記録
--   (2) 完了した受付日だけ処理済みにする(incomplete は次回もう一度処理する)
--   (3) 今回の実行で各タスクがどう終わったか(SUCCEEDED / FAILED / SKIPPED と戻り値)を記録
-- (3) は TASK_HISTORY の反映待ちなどで失敗しうるため最後に置く。
--
-- Pipeline Builder の設定
--   種類                  : SQL file(このファイル)
--   グラフの Finalizer に設定する(Predecessors・条件は設定しない)
-- =====================================================================
USE SCHEMA DECISION_PIPE_DB.SUPPORT;

-- (1) サマリ
INSERT INTO RUN_SUMMARY
  (RUN_GROUP_ID, BATCH_DATES, N_TICKETS, CLASSIFY_MODEL, QUALITY_MODEL,
   N_AUTO, N_AGENT, N_HUMAN, N_UNSAFE_AUTOMATION, N_MISSED_AUTOMATION, CATEGORY_ACC, STATUS)
WITH d AS (
  SELECT LISTAGG(TO_VARCHAR(RECEIVED_DATE, 'YYYY-MM-DD'), ',') WITHIN GROUP (ORDER BY RECEIVED_DATE) AS dates
  FROM CURRENT_BATCH_DATES
),
agg AS (
  SELECT
    COUNT(b.TICKET_ID)                                                            AS n_tickets,
    COUNT(f.TICKET_ID)                                                            AS n_final,
    MAX(c.CLASSIFY_MODEL)                                                         AS classify_model,
    MAX(f.QUALITY_MODEL)                                                          AS quality_model,
    COUNT_IF(f.FINAL_ROUTE = 'auto')                                              AS n_auto,
    COUNT_IF(f.FINAL_ROUTE = 'agent')                                             AS n_agent,
    COUNT_IF(f.FINAL_ROUTE = 'human')                                             AS n_human,
    COUNT_IF(f.FINAL_ROUTE IN ('auto', 'agent') AND l.TRUE_RESOLUTION = 'human')  AS n_unsafe,
    COUNT_IF(f.FINAL_ROUTE = 'human' AND l.TRUE_RESOLUTION IN ('kb', 'lookup'))   AS n_missed,
    AVG(IFF(c.CATEGORY IS NULL, NULL, IFF(c.CATEGORY = l.TRUE_CATEGORY, 1, 0)))   AS category_acc
  FROM CURRENT_BATCH b
  LEFT JOIN FINAL_RESULTS f    ON f.TICKET_ID = b.TICKET_ID
  LEFT JOIN CLASSIFY_RESULTS c ON c.TICKET_ID = b.TICKET_ID
  LEFT JOIN TICKET_LABELS l    ON l.TICKET_ID = b.TICKET_ID
)
SELECT
  SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_GRAPH_RUN_GROUP_ID'),
  d.dates, agg.n_tickets, agg.classify_model, agg.quality_model,
  agg.n_auto, agg.n_agent, agg.n_human, agg.n_unsafe, agg.n_missed, agg.category_acc,
  CASE WHEN agg.n_tickets = 0 THEN 'no_tickets'
       WHEN agg.n_final = agg.n_tickets THEN 'complete'
       ELSE 'incomplete' END
FROM agg CROSS JOIN d;

-- (2) 完了した受付日を処理済みにする
INSERT INTO BATCH_STATE (RECEIVED_DATE, RUN_GROUP_ID)
SELECT d.RECEIVED_DATE, SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_GRAPH_RUN_GROUP_ID')
FROM CURRENT_BATCH_DATES d
WHERE NOT EXISTS (SELECT 1 FROM BATCH_STATE s WHERE s.RECEIVED_DATE = d.RECEIVED_DATE)
  AND NOT EXISTS (   -- その日のチケットがすべて最終結果まで進んでいる(0件の日も含む)
        SELECT 1 FROM CURRENT_BATCH b
        LEFT JOIN FINAL_RESULTS f ON f.TICKET_ID = b.TICKET_ID
        WHERE b.RECEIVED_DATE = d.RECEIVED_DATE AND f.TICKET_ID IS NULL);

-- (3) 今回の実行で各タスクがどう終わったか
INSERT INTO RUN_TASK_STATES
  (RUN_GROUP_ID, TASK_NAME, STATE, RETURN_VALUE, ERROR_MESSAGE, QUERY_START_TIME, COMPLETED_TIME)
SELECT GRAPH_RUN_GROUP_ID, NAME, STATE, RETURN_VALUE, ERROR_MESSAGE, QUERY_START_TIME, COMPLETED_TIME
FROM TABLE(DECISION_PIPE_DB.INFORMATION_SCHEMA.TASK_HISTORY(
       SCHEDULED_TIME_RANGE_START => DATEADD('day', -1, CURRENT_TIMESTAMP()),
       RESULT_LIMIT => 10000))
WHERE GRAPH_RUN_GROUP_ID = SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_GRAPH_RUN_GROUP_ID');
