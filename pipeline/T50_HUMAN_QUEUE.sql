-- =====================================================================
-- T50_HUMAN_QUEUE  [通常]
-- 担当者行きがあるときだけ動く。キュー投入と、担当者向け引き継ぎメモの生成
--
-- Pipeline Builder の設定(Task タブ > Dependencies)
--   Predecessors          : T40_FINALIZE_ANSWERS
--   Predecessors condition: All succeeded(既定)
--   Additional conditions : SYSTEM$GET_PREDECESSOR_RETURN_VALUE('T40_FINALIZE_ANSWERS') = 'REVIEW_NEEDED'
-- =====================================================================
CALL DECISION_PIPE_DB.SUPPORT.SP_ENQUEUE_REVIEW('final');
