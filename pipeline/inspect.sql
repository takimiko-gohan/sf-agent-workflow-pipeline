-- =====================================================================
-- inspect.sql
-- グラフ実行後の確認クエリ
-- =====================================================================

USE ROLE DECISION_PIPE_ROLE;
USE WAREHOUSE DECISION_PIPE_WH;
USE SCHEMA DECISION_PIPE_DB.SUPPORT;

-- 1. 実行ごとに通った経路(ファイナライザーが記録)
SELECT LOGGED_AT, BATCH_DATES, STATUS, PATH
FROM V_RUN_PATH
ORDER BY LOGGED_AT DESC
LIMIT 10;

-- 2. タスク履歴を直接見る(RETURN_VALUE に戻り値が入っているかをここで確認する)
SELECT GRAPH_RUN_GROUP_ID, NAME, STATE, RETURN_VALUE, ERROR_MESSAGE, QUERY_START_TIME, COMPLETED_TIME
FROM TABLE(DECISION_PIPE_DB.INFORMATION_SCHEMA.TASK_HISTORY(
       SCHEDULED_TIME_RANGE_START => DATEADD('hour', -6, CURRENT_TIMESTAMP()),
       RESULT_LIMIT => 200))
ORDER BY SCHEDULED_TIME DESC, QUERY_START_TIME;

-- 3. 実行サマリ
--    N_UNSAFE_AUTOMATION: 担当者が必要なのに自動で回答した件数(0 であるべき)
--    N_MISSED_AUTOMATION: 自動で回答できたのに担当者に回した件数(少ないほど効率的)
SELECT LOGGED_AT, BATCH_DATES, N_TICKETS, CLASSIFY_MODEL, QUALITY_MODEL,
       N_AUTO, N_AGENT, N_HUMAN, N_UNSAFE_AUTOMATION, N_MISSED_AUTOMATION,
       ROUND(CATEGORY_ACC, 3) AS CATEGORY_ACC, STATUS
FROM RUN_SUMMARY
ORDER BY LOGGED_AT DESC;

-- 4. 問い合わせと返信を読む(送信可のもの)
SELECT TICKET_ID, SUBJECT, ROUTE, FINAL_ROUTE, QUALITY_SCORE, FINAL_REPLY
FROM V_TICKET_RESULTS
WHERE FINAL_ROUTE IN ('auto', 'agent')
ORDER BY TICKET_ID DESC
LIMIT 20;

-- 5. 担当者キュー(理由・下書き・引き継ぎメモ)
SELECT q.TICKET_ID, q.REASON, q.SOURCE_TASK, t.SUBJECT, q.DRAFT_REPLY, q.HANDOFF_NOTE
FROM HUMAN_REVIEW_QUEUE q
JOIN SUPPORT_TICKETS t ON t.TICKET_ID = q.TICKET_ID
ORDER BY q.ENQUEUED_AT DESC
LIMIT 20;

SELECT REASON, SOURCE_TASK, COUNT(*) AS N
FROM HUMAN_REVIEW_QUEUE GROUP BY 1, 2 ORDER BY 1, 2;

-- 6. イベントログ
SELECT LOGGED_AT, TASK, EVENT, DETAIL
FROM PIPELINE_EVENTS ORDER BY LOGGED_AT DESC LIMIT 50;

-- =====================================================================
-- 評価(累計、正解ラベルとの突合)
-- =====================================================================

-- 7. 振り分けの正しさ: 正解の処理区分 × 最初の振り分け × 最終結果
--    理想: kb → auto、lookup → agent、human → human
SELECT l.TRUE_RESOLUTION, r.ROUTE, f.FINAL_ROUTE, COUNT(*) AS N
FROM FINAL_RESULTS f
JOIN ROUTED_TICKETS r USING (TICKET_ID)
JOIN TICKET_LABELS l  USING (TICKET_ID)
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;

-- 8. 安全性と効率
SELECT
  c.CLASSIFY_MODEL,
  COUNT(*)                                                                              AS tickets,
  ROUND(AVG(IFF(c.CATEGORY = l.TRUE_CATEGORY, 1, 0)), 3)                                AS category_acc,
  ROUND(COUNT_IF(l.TRUE_RESOLUTION = 'human' AND f.FINAL_ROUTE = 'human')
        / NULLIF(COUNT_IF(l.TRUE_RESOLUTION = 'human'), 0), 3)                          AS human_recall,      -- 1.0 が目標
  COUNT_IF(l.TRUE_RESOLUTION = 'human' AND f.FINAL_ROUTE IN ('auto', 'agent'))          AS unsafe_automation, -- 0 が目標
  ROUND(COUNT_IF(f.FINAL_ROUTE IN ('auto', 'agent'))
        / NULLIF(COUNT_IF(l.TRUE_RESOLUTION IN ('kb', 'lookup')), 0), 3)                AS automation_rate
FROM FINAL_RESULTS f
JOIN TICKET_LABELS l USING (TICKET_ID)
LEFT JOIN CLASSIFY_RESULTS c USING (TICKET_ID)
GROUP BY c.CLASSIFY_MODEL;

-- 9. 回答の中身
--    kb_match : 定型回答で選んだヘルプ記事が正解と一致した割合
--    fact_hit : 顧客データが必要な問い合わせで、回答に正しい値(金額・上限など)が含まれた割合
SELECT
  ROUND(AVG(IFF(f.FINAL_ROUTE = 'auto', IFF(r.KB_ID = l.TRUE_KB_ID, 1, 0), NULL)), 3) AS kb_match,
  ROUND(AVG(IFF(l.TRUE_RESOLUTION = 'lookup' AND f.FINAL_ROUTE IN ('auto', 'agent') AND l.EXPECTED_FACT IS NOT NULL,
                IFF(CONTAINS(REGEXP_REPLACE(f.FINAL_REPLY, '[,，]', ''), l.EXPECTED_FACT), 1, 0), NULL)), 3) AS fact_hit
FROM FINAL_RESULTS f
JOIN ROUTED_TICKETS r USING (TICKET_ID)
JOIN TICKET_LABELS l  USING (TICKET_ID);

-- 10. 自動回答してしまった「要担当者」の問い合わせ(要チェック)
SELECT t.TICKET_ID, l.TEMPLATE_ID, t.SUBJECT, r.HUMAN_PROB, f.FINAL_ROUTE, f.FINAL_REPLY
FROM FINAL_RESULTS f
JOIN TICKET_LABELS l   USING (TICKET_ID)
JOIN ROUTED_TICKETS r  USING (TICKET_ID)
JOIN SUPPORT_TICKETS t USING (TICKET_ID)
WHERE l.TRUE_RESOLUTION = 'human' AND f.FINAL_ROUTE IN ('auto', 'agent');

-- =====================================================================
-- 判定モデル(decider-2b)の確率を見る
-- =====================================================================

-- 11. 確率の較正: 要担当者の確率(HUMAN_PROB)の帯ごとに、実際に要担当者だった割合
--     確率どおりに当たっていれば、avg_prob と actual_rate が近い値になる。
--     human_min(既定 0.5)をどこに置けば unsafe_automation を0にできるかの判断材料
SELECT
  c.CLASSIFY_MODEL,
  FLOOR(c.HUMAN_PROB * 10) / 10                                          AS prob_bucket,
  COUNT(*)                                                               AS n,
  ROUND(AVG(c.HUMAN_PROB), 3)                                            AS avg_prob,
  ROUND(AVG(IFF(l.TRUE_RESOLUTION = 'human', 1, 0)), 3)                  AS actual_rate
FROM CLASSIFY_RESULTS c
JOIN TICKET_LABELS l USING (TICKET_ID)
WHERE c.HUMAN_PROB IS NOT NULL
GROUP BY 1, 2
ORDER BY 1, 2;

-- 12. 同じく、顧客データが必要な確率(ACCOUNT_DATA_PROB)の較正
SELECT
  c.CLASSIFY_MODEL,
  FLOOR(c.ACCOUNT_DATA_PROB * 10) / 10                                   AS prob_bucket,
  COUNT(*)                                                               AS n,
  ROUND(AVG(c.ACCOUNT_DATA_PROB), 3)                                     AS avg_prob,
  ROUND(AVG(IFF(l.TRUE_RESOLUTION = 'lookup', 1, 0)), 3)                 AS actual_rate
FROM CLASSIFY_RESULTS c
JOIN TICKET_LABELS l USING (TICKET_ID)
WHERE c.ACCOUNT_DATA_PROB IS NOT NULL AND l.TRUE_RESOLUTION <> 'human'
GROUP BY 1, 2
ORDER BY 1, 2;

-- 13. 閾値を動かしたらどうなるか(human_min の候補ごとの取りこぼしと人手送り)
SELECT
  th.v                                                                    AS human_min,
  COUNT_IF(l.TRUE_RESOLUTION = 'human' AND c.HUMAN_PROB <  th.v)          AS missed_human,     -- 0 にしたい
  COUNT_IF(l.TRUE_RESOLUTION <> 'human' AND c.HUMAN_PROB >= th.v)         AS extra_to_human,   -- 少ないほど効率的
  COUNT(*)                                                                AS n
FROM CLASSIFY_RESULTS c
JOIN TICKET_LABELS l USING (TICKET_ID)
CROSS JOIN (SELECT * FROM VALUES (0.2), (0.3), (0.4), (0.5), (0.6), (0.7)) th (v)
WHERE c.CLASSIFY_MODEL = 'decider-2b'
GROUP BY th.v
ORDER BY th.v;

-- 14. decider-2b の処理時間と入力トークン(1件あたり、サービス内の時間)
SELECT
  COUNT(*)                                                                AS n,
  ROUND(MEDIAN(RAW:elapsed_ms::FLOAT), 1)                                 AS median_ms,
  ROUND(APPROX_PERCENTILE(RAW:elapsed_ms::FLOAT, 0.95), 1)                AS p95_ms,
  ROUND(AVG(RAW:input_tokens::INT))                                       AS avg_input_tokens,
  COUNT_IF(RAW:answer:error IS NOT NULL)                                  AS row_errors
FROM CLASSIFY_RESULTS
WHERE CLASSIFY_MODEL = 'decider-2b';
