-- =====================================================================
-- scenarios.sql
-- 分岐の検証シナリオ。シナリオを切り替えてから Pipeline Builder でグラフを
-- 手動実行(Run)し、inspect.sql で通った経路と回答を確認する。
-- 強制失敗のシナリオを試すときは、グラフのリトライ回数を 0 にしておくこと。
-- =====================================================================

USE ROLE DECISION_PIPE_ROLE;
USE WAREHOUSE DECISION_PIPE_WH;
USE SCHEMA DECISION_PIPE_DB.SUPPORT;

-- 受付日ごとのチケット件数(どの日を処理するかの目安)
SELECT * FROM V_BATCH_PREVIEW ORDER BY RECEIVED_DATE;

-- 前提: decider-2b のサービスが READY であること(setup/05_decider_model.sql の [2])
SELECT SYSTEM$GET_SERVICE_STATUS('DECISION_PIPE_DB.SUPPORT.DECIDER_2B_SVC');

-- 0. 最初からやり直す(結果を全消去し、設定を normal に戻す)
CALL SP_SET_SCENARIO('reset');

-- 1. 通常: 1日分を処理
--    期待: T00(HAS_TICKETS) → T07(英訳) → T10 → T20 → T30 → T40 → T50 → T99
--          T05 / T11 / T31 / T35 は SKIPPED
--    ※ agent 行が上限(既定5件)を超えた日は AGENT_OVERFLOW になり、T31 も動く
CALL SP_SET_SCENARIO('normal');
-- → グラフを Run

-- 2. 判定モデル障害: decider-2b での分類(T10)を失敗させ、フォールバックに切り替わるか
--    期待: T10=FAILED → T11 → T20 → …(CLASSIFY_MODEL が llm-fallback になる)
--    ※ DECIDER_2B_SVC が存在しない・起動していない場合も、normal で自然にこの経路になる
CALL SP_SET_SCENARIO('classify_down');
-- → グラフを Run

-- 3. エージェント障害: T30 を失敗させ、退避処理に切り替わるか
--    期待: T30=FAILED → T35(担当者キューへ退避) → T40(agent の行は human) → T50
CALL SP_SET_SCENARIO('agent_down');
-- → グラフを Run

-- 4. 処理量超過: エージェント上限を1件にする
--    期待: T20(AGENT_OVERFLOW) → T30 と T31 が並列 → T40 → T50
CALL SP_SET_SCENARIO('overflow');
-- → グラフを Run

-- 5. 処理対象なし: 全日を処理済みにする
--    期待: T00(NO_TICKETS) → T05 のみ。T10 以降はすべて SKIPPED、T99 は実行される
--    ※ 日曜でチケット0件の日も同じ経路になる
CALL SP_SET_SCENARIO('drained');
-- → グラフを Run

-- 6. 翻訳の効果を比べる: 英訳せずに日本語のまま decider-2b に渡す
--    手順: reset → translate_for_decider = 0 で数日分 Run → reset → = 1 で同じ日を Run し、
--          inspect.sql の 15(INPUT_LANG 別の正解率・確率の較正)を比べる
--    ※ reset で結果が消えるので、比較したい指標は reset 前に控えておく
--      (RUN_SUMMARY は消えるが、CLASSIFY_RESULTS を別テーブルに CTAS で退避しておくと比べやすい)
-- UPDATE PIPELINE_CONFIG SET VALUE = 0 WHERE KEY = 'translate_for_decider';   -- 日本語のまま
-- UPDATE PIPELINE_CONFIG SET VALUE = 1 WHERE KEY = 'translate_for_decider';   -- 英訳する(既定)
-- CREATE OR REPLACE TABLE CLASSIFY_RESULTS_JA AS SELECT * FROM CLASSIFY_RESULTS;  -- 退避の例

-- 7. 一括処理: グラフの Config (JSON) を {"batch_mode": "all"} にして Deploy し直すと、
--    未処理の日をまとめて1回で処理する(overflow 経路になりやすい)
CALL SP_SET_SCENARIO('reset');
-- → Config を変更して Deploy → Run


-- ---------------------------------------------------------------------
-- (参考)グラフを使わずにワークシートで1回分を順に流す場合
--   戻り値は設定されない(タスク外では無視される)ので、RETURN の文字列を見て手で分岐する
-- ---------------------------------------------------------------------
-- CALL SP_PICK_BATCH();
-- CALL SP_TRANSLATE();
-- CALL SP_CLASSIFY('decider');         -- 失敗したら CALL SP_CLASSIFY('llm');
-- CALL SP_ROUTE();
-- CALL SP_RUN_AGENT_BATCH();           -- ROUTE が ALL_AUTO なら不要
-- CALL SP_ENQUEUE_REVIEW('overflow');  -- ROUTE が AGENT_OVERFLOW のときのみ
-- CALL SP_FINALIZE_ANSWERS();
-- CALL SP_ENQUEUE_REVIEW('final');     -- REVIEW_NEEDED のときのみ
-- CALL SP_RUN_SUMMARY();
