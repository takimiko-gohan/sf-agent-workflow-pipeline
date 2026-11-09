-- =====================================================================
-- T50_REVIEW_QUEUE  [通常]
-- 人手行があるときだけ動く
--
-- Pipeline Builder の設定(Task タブ > Dependencies)
--   Predecessors          : T40_FINALIZE_RESULTS
--   Predecessors condition: All succeeded(既定)
--   Additional conditions : SYSTEM$GET_PREDECESSOR_RETURN_VALUE('T40_FINALIZE_RESULTS') = 'REVIEW_NEEDED'
-- =====================================================================
CALL DECISION_PIPE_DB.DEMO.SP_ENQUEUE_REVIEW('final');
