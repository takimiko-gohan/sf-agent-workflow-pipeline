-- =====================================================================
-- scenarios.sql
-- 分岐の検証シナリオ。シナリオを切り替えてから、Pipeline Builder で
-- グラフを手動実行(Run)し、inspect.sql で通った経路を確認する。
-- 強制失敗のシナリオを試すときは、グラフのリトライ回数を 0 にしておくこと
-- (リトライすると同じ失敗を繰り返すだけで、結果の確認に時間がかかる)。
-- =====================================================================

USE ROLE DECISION_PIPE_ROLE;
USE WAREHOUSE DECISION_PIPE_WH;
USE SCHEMA DECISION_PIPE_DB.DEMO;

-- 0. 最初からやり直す(結果を全消去し、設定を normal に戻す)
CALL SP_SET_SCENARIO('reset');

-- 1. 通常: 1日分を処理
--    期待: T00(HAS_ALERTS) → T10 → T20 → T30 → T40 → (人手行があれば T50) → T99
--          T05 / T11 / T31 / T35 は SKIPPED
CALL SP_SET_SCENARIO('normal');
-- → グラフを Run

-- 2. 判定モデル障害: T10 を失敗させ、フォールバックに切り替わるか
--    期待: T10=FAILED → T11 → T20 → …(DECISION_MODEL が llm-fallback になる)
--    ※ snowflake-decision が未有効化のアカウントでは、normal でも自然にこの経路になる
CALL SP_SET_SCENARIO('decision_down');
-- → グラフを Run

-- 3. エージェント障害: T30 を失敗させ、退避処理に切り替わるか
--    期待: T30=FAILED → T35(人手キューへ退避) → T40(エージェント対象は human) → T50
CALL SP_SET_SCENARIO('agent_down');
-- → グラフを Run

-- 4. 処理量超過: エージェント上限を1件にして、上限超過の分岐を見る
--    期待: T20(AGENT_OVERFLOW) → T30 と T31 が並列 → T40 → T50
CALL SP_SET_SCENARIO('overflow');
-- → グラフを Run

-- 5. 処理対象なし: 全日を処理済みにして、空振りの分岐を見る
--    期待: T00(NO_ALERTS) → T05 のみ。T10 以降はすべて SKIPPED、T99 は実行される
CALL SP_SET_SCENARIO('drained');
-- → グラフを Run

-- 6. 一括処理: グラフの Config (JSON) を {"batch_mode": "all"} にして Deploy し直すと、
--    未処理の日をまとめて1回で処理する(エージェント上限に当たりやすく、overflow 経路になりやすい)
CALL SP_SET_SCENARIO('reset');
-- → Config を変更して Deploy → Run


-- ---------------------------------------------------------------------
-- (参考)グラフを使わずにワークシートで1回分を順に流す場合
--   戻り値は設定されない(タスク外では無視される)ので、分岐は RETURN の文字列を見て手で判断する
-- ---------------------------------------------------------------------
-- CALL SP_PICK_BATCH();
-- CALL SP_DECIDE('decision');        -- 失敗したら CALL SP_DECIDE('llm');
-- CALL SP_ROUTE();
-- CALL SP_RUN_AGENT_BATCH();         -- ROUTE が ALL_AUTO なら不要
-- CALL SP_ENQUEUE_REVIEW('overflow');-- ROUTE が AGENT_OVERFLOW のときのみ
-- CALL SP_FINALIZE_RESULTS();
-- CALL SP_ENQUEUE_REVIEW('final');   -- REVIEW_NEEDED のときのみ
-- CALL SP_RUN_SUMMARY();
