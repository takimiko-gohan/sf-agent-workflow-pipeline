-- =====================================================================
-- scenarios.sql
-- 分岐の検証シナリオ。設定を切り替えてから Pipeline Builder でグラフを手動実行(Run)し、
-- inspect.sql で通った経路と回答を確認する。
-- 強制失敗のシナリオを試すときは、グラフのリトライ回数を 0 にしておくこと。
-- =====================================================================

USE ROLE DECISION_PIPE_ROLE;
USE WAREHOUSE DECISION_PIPE_WH;
USE SCHEMA DECISION_PIPE_DB.SUPPORT;

-- 前提: decider-2b のサービスが READY であること(setup/05_decider_model.sql の [2])
SELECT SYSTEM$GET_SERVICE_STATUS('DECISION_PIPE_DB.SUPPORT.DECIDER_2B_SVC');

-- 受付日ごとのチケット件数(どの日を処理するかの目安)
SELECT * FROM V_BATCH_PREVIEW ORDER BY RECEIVED_DATE;

-- ---------------------------------------------------------------------
-- 設定の切り替え(シナリオ用のフラグをまとめて戻す)
-- ---------------------------------------------------------------------
-- normal(通常)に戻す
UPDATE PIPELINE_CONFIG
   SET VALUE = CASE KEY WHEN 'agent_max_rows' THEN 5 ELSE 0 END
 WHERE KEY IN ('force_classify_failure', 'force_agent_failure', 'force_quality_failure', 'agent_max_rows');

-- ---------------------------------------------------------------------
-- 0. 最初からやり直す(結果を全消去)
-- ---------------------------------------------------------------------
TRUNCATE TABLE BATCH_STATE;
TRUNCATE TABLE CURRENT_BATCH_DATES;
TRUNCATE TABLE CURRENT_BATCH;
TRUNCATE TABLE TICKET_TRANSLATIONS;
TRUNCATE TABLE KB_TRANSLATIONS;
TRUNCATE TABLE CLASSIFY_RESULTS;
TRUNCATE TABLE ROUTED_TICKETS;
TRUNCATE TABLE AGENT_RESULTS;
TRUNCATE TABLE AUTO_ANSWERS;
TRUNCATE TABLE QUALITY_CANDIDATES;
TRUNCATE TABLE QUALITY_SCORES;
TRUNCATE TABLE FINAL_RESULTS;
TRUNCATE TABLE HUMAN_REVIEW_QUEUE;
TRUNCATE TABLE PIPELINE_EVENTS;
TRUNCATE TABLE RUN_SUMMARY;
TRUNCATE TABLE RUN_TASK_STATES;

-- ---------------------------------------------------------------------
-- 1. 通常(上の「normal に戻す」を実行してから Run)
--    期待: T00(HAS_TICKETS) → T07 → T10 → T20 → T30 → T40 → T41 → T45 → T50 → T99
--          T05 / T11 / T31 / T35 / T42 は SKIPPED
--    ※ agent 行が上限(既定5件)を超えた日は AGENT_OVERFLOW になり、T31 も動く
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- 2. 分類の判定モデル障害: T10 を失敗させ、T11(汎用LLM)に切り替わるか
--    期待: T10=FAILED → T11 → T20 → …(CLASSIFY_MODEL が llm-fallback)
--    ※ DECIDER_2B_SVC が無い・起動していない場合も、通常の Run でこの経路になる
-- ---------------------------------------------------------------------
UPDATE PIPELINE_CONFIG SET VALUE = 1 WHERE KEY = 'force_classify_failure';

-- ---------------------------------------------------------------------
-- 3. エージェント障害: T30 を失敗させ、T35 の退避に切り替わるか
--    期待: T30=FAILED → T35 → T40 → T41 → T45(agent の行は human)→ T50
-- ---------------------------------------------------------------------
UPDATE PIPELINE_CONFIG SET VALUE = 1 WHERE KEY = 'force_agent_failure';

-- ---------------------------------------------------------------------
-- 4. 品質チェックの判定モデル障害: T41 を失敗させ、T42(汎用LLM)に切り替わるか
--    期待: T41=FAILED → T42 → T45 → …(QUALITY_MODEL が llm-fallback)
-- ---------------------------------------------------------------------
UPDATE PIPELINE_CONFIG SET VALUE = 1 WHERE KEY = 'force_quality_failure';

-- ---------------------------------------------------------------------
-- 5. 処理量超過: エージェントの上限を1件にする
--    期待: T20(AGENT_OVERFLOW)→ T30 と T31 が並列 → T40 → …
-- ---------------------------------------------------------------------
UPDATE PIPELINE_CONFIG SET VALUE = 1 WHERE KEY = 'agent_max_rows';

-- ---------------------------------------------------------------------
-- 6. 処理対象なし: 全日を処理済みにする
--    期待: T00(NO_TICKETS)→ T05 のみ。T07 以降はすべて SKIPPED、T99 は実行される
--    ※ 日曜でチケット0件の日も同じ経路になる
-- ---------------------------------------------------------------------
INSERT INTO BATCH_STATE (RECEIVED_DATE, RUN_GROUP_ID)
SELECT c.RECEIVED_DATE, 'scenario:drained' FROM BATCH_CALENDAR c
WHERE NOT EXISTS (SELECT 1 FROM BATCH_STATE s WHERE s.RECEIVED_DATE = c.RECEIVED_DATE);

-- ---------------------------------------------------------------------
-- 7. 翻訳の効果を比べる: 英訳せずに日本語のまま decider-2b に渡す
--    手順: 0 で全消去 → translate_for_decider = 0 で数日分 Run → 結果を退避 →
--          0 で全消去 → = 1 で同じ日を Run → inspect.sql の 15 で比べる
-- ---------------------------------------------------------------------
-- UPDATE PIPELINE_CONFIG SET VALUE = 0 WHERE KEY = 'translate_for_decider';      -- 日本語のまま
-- UPDATE PIPELINE_CONFIG SET VALUE = 1 WHERE KEY = 'translate_for_decider';      -- 英訳する(既定)
-- CREATE OR REPLACE TABLE CLASSIFY_RESULTS_JA AS SELECT * FROM CLASSIFY_RESULTS; -- 退避の例

-- ---------------------------------------------------------------------
-- 8. 翻訳の失敗: T07 が失敗しても T10 が日本語のまま分類を続けるか
--    期待: T07=FAILED → T10(INPUT_LANG = ja)→ …
--    T07 を確実に失敗させるフラグは用意していない。試す場合は、カードの先頭に
--      SELECT TO_NUMBER('強制失敗: 翻訳');
--    を一時的に足して Deploy する。
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- 9. 一括処理: グラフの Config (JSON) を {"batch_mode": "all"} にして Deploy し直すと、
--    未処理の日をまとめて1回で処理する(overflow 経路になりやすい)
-- ---------------------------------------------------------------------
