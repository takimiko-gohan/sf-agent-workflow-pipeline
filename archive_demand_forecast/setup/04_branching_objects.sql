-- =====================================================================
-- 04_branching_objects.sql
-- Pipeline Builder の分岐機能(戻り値による分岐・前段の完了状態による分岐・
-- ファイナライザー)を検証するためのテーブルとプロシージャを作成する。
-- 前提: 00〜03 を実行済み
--
-- 各カードは「CALL <プロシージャ>」1文だけにして、ロジックはここに集約する。
-- 戻り値の設定(SYSTEM$SET_RETURN_VALUE)はプロシージャ内で行い、タスク外
-- (ワークシート)から呼んだ場合は無視されるようにしてあるので、手動でも試せる。
-- =====================================================================

USE ROLE DECISION_PIPE_ROLE;
USE WAREHOUSE DECISION_PIPE_WH;
USE SCHEMA DECISION_PIPE_DB.DEMO;

-- =====================================================================
-- 1. 設定値
-- =====================================================================
MERGE INTO PIPELINE_CONFIG t
USING (
  SELECT * FROM VALUES
    ('force_decision_failure',   0,   '1 にすると判定(T10)を強制失敗させる(フォールバック検証用)'),
    ('force_agent_failure',      0,   '1 にするとエージェント調査(T30)を強制失敗させる'),
    ('agent_error_max',          0.5, 'エージェント呼び出しの失敗率がこれを超えたら T30 を失敗扱いにする'),
    ('use_decision_for_quality', 1,   '1=品質チェックに snowflake-decision を使う(失敗時は自動で汎用LLM)/0=汎用LLMのみ')
) s (KEY, VALUE, NOTE)
ON t.KEY = s.KEY
WHEN NOT MATCHED THEN INSERT (KEY, VALUE, NOTE) VALUES (s.KEY, s.VALUE, s.NOTE);

-- 分岐が起きやすいよう、1回の実行でエージェントに回す件数を小さめにする
UPDATE PIPELINE_CONFIG SET VALUE = 5 WHERE KEY = 'agent_max_rows';

-- 設定値の参照用関数
CREATE OR REPLACE FUNCTION CFG(K VARCHAR)
RETURNS FLOAT
AS
$$
  SELECT MAX(VALUE) FROM DECISION_PIPE_DB.DEMO.PIPELINE_CONFIG WHERE KEY = K
$$;

-- =====================================================================
-- 2. テーブル
-- =====================================================================
-- 1日を1バッチとして処理する対象日(異常注入期間の30日)
CREATE OR REPLACE TABLE BATCH_CALENDAR AS
SELECT DISTINCT SALES_DATE
FROM FACT_SALES_DAILY
WHERE SALES_DATE >= '2026-10-02'::DATE;

CREATE OR REPLACE TABLE ALERT_BATCH_STATE (
  SALES_DATE   DATE,
  RUN_GROUP_ID VARCHAR,
  PROCESSED_AT TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
) COMMENT = '処理済みのバッチ日';

CREATE OR REPLACE TABLE CURRENT_BATCH_DATES (SALES_DATE DATE)
  COMMENT = '今回の実行で処理する日';
CREATE OR REPLACE TABLE CURRENT_BATCH (ALERT_ID NUMBER, SALES_DATE DATE)
  COMMENT = '今回の実行で処理するアラート';

ALTER TABLE ROUTED_ALERTS ADD COLUMN IF NOT EXISTS AGENT_PRIORITY NUMBER;
ALTER TABLE FINAL_RESULTS ADD COLUMN IF NOT EXISTS HUMAN_REASON VARCHAR;
ALTER TABLE FINAL_RESULTS ADD COLUMN IF NOT EXISTS QUALITY_MODEL VARCHAR;

CREATE OR REPLACE TABLE HUMAN_REVIEW_QUEUE (
  ALERT_ID    NUMBER,
  REASON      VARCHAR,          -- overflow / agent_failed / agent_error / low_quality など
  SOURCE_TASK VARCHAR,
  ALERT_TEXT  VARCHAR,
  STATUS      VARCHAR DEFAULT 'open',
  ENQUEUED_AT TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
) COMMENT = '人手レビュー待ちのアラート';

CREATE OR REPLACE TABLE PIPELINE_EVENTS (
  LOGGED_AT    TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
  RUN_GROUP_ID VARCHAR,
  TASK         VARCHAR,
  EVENT        VARCHAR,
  DETAIL       VARCHAR
) COMMENT = '各カードが出すイベントログ';

CREATE OR REPLACE TABLE RUN_SUMMARY (
  LOGGED_AT      TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
  RUN_GROUP_ID   VARCHAR,
  BATCH_DATES    VARCHAR,
  N_ALERTS       NUMBER,
  DECISION_MODEL VARCHAR,
  QUALITY_MODEL  VARCHAR,
  N_AUTO         NUMBER,
  N_AGENT        NUMBER,
  N_HUMAN        NUMBER,
  AUTOMATED_ACC  FLOAT,
  STATUS         VARCHAR        -- complete / incomplete / no_alerts
) COMMENT = 'ファイナライザーが記録する実行ごとのサマリ';

CREATE OR REPLACE TABLE RUN_TASK_STATES (
  RUN_GROUP_ID     VARCHAR,
  TASK_NAME        VARCHAR,
  STATE            VARCHAR,
  RETURN_VALUE     VARCHAR,
  ERROR_MESSAGE    VARCHAR,
  QUERY_START_TIME TIMESTAMP_LTZ,
  COMPLETED_TIME   TIMESTAMP_LTZ
) COMMENT = 'ファイナライザーが記録する、その実行で各タスクがどう終わったか(通った経路)';

-- =====================================================================
-- 3. 共通: イベントログ
-- =====================================================================
CREATE OR REPLACE PROCEDURE SP_LOG_EVENT(P_TASK VARCHAR, P_EVENT VARCHAR, P_DETAIL VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  gid VARCHAR DEFAULT NULL;
BEGIN
  BEGIN
    SELECT SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_GRAPH_RUN_GROUP_ID') INTO :gid;
  EXCEPTION
    WHEN OTHER THEN gid := NULL;
  END;
  INSERT INTO PIPELINE_EVENTS (RUN_GROUP_ID, TASK, EVENT, DETAIL)
  VALUES (:gid, :P_TASK, :P_EVENT, :P_DETAIL);
  RETURN P_EVENT;
END;
$$;

-- =====================================================================
-- 4. T00 (ルート): 今回処理するバッチを決める
--    戻り値: HAS_ALERTS / NO_ALERTS
--    グラフの Config (JSON) の batch_mode を読む('daily'=1日ずつ / 'all'=未処理を全部)
-- =====================================================================
CREATE OR REPLACE PROCEDURE SP_PICK_BATCH()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  bmode   VARCHAR DEFAULT 'daily';
  n       NUMBER DEFAULT 0;
  n_dates NUMBER DEFAULT 0;
  dates   VARCHAR;
  rv      VARCHAR;
BEGIN
  BEGIN
    SELECT COALESCE(SYSTEM$GET_TASK_GRAPH_CONFIG('batch_mode')::VARCHAR, 'daily') INTO :bmode;
  EXCEPTION
    WHEN OTHER THEN bmode := 'daily';     -- タスク外から呼んだ場合など
  END;

  TRUNCATE TABLE CURRENT_BATCH_DATES;
  TRUNCATE TABLE CURRENT_BATCH;

  IF (bmode = 'all') THEN
    INSERT INTO CURRENT_BATCH_DATES
    SELECT c.SALES_DATE FROM BATCH_CALENDAR c
    WHERE NOT EXISTS (SELECT 1 FROM ALERT_BATCH_STATE s WHERE s.SALES_DATE = c.SALES_DATE);
  ELSE
    INSERT INTO CURRENT_BATCH_DATES
    SELECT MIN(c.SALES_DATE) FROM BATCH_CALENDAR c
    WHERE NOT EXISTS (SELECT 1 FROM ALERT_BATCH_STATE s WHERE s.SALES_DATE = c.SALES_DATE)
    HAVING MIN(c.SALES_DATE) IS NOT NULL;
  END IF;

  INSERT INTO CURRENT_BATCH (ALERT_ID, SALES_DATE)
  SELECT a.ALERT_ID, a.SALES_DATE
  FROM FORECAST_ALERTS a
  JOIN CURRENT_BATCH_DATES d ON d.SALES_DATE = a.SALES_DATE;
  n := SQLROWCOUNT;

  SELECT COUNT(*), LISTAGG(TO_VARCHAR(SALES_DATE, 'YYYY-MM-DD'), ',') WITHIN GROUP (ORDER BY SALES_DATE)
    INTO :n_dates, :dates
  FROM CURRENT_BATCH_DATES;

  rv := IFF(n > 0, 'HAS_ALERTS', 'NO_ALERTS');
  BEGIN
    CALL SYSTEM$SET_RETURN_VALUE(:rv);
  EXCEPTION
    WHEN OTHER THEN NULL;                -- タスク外では戻り値を設定できないので無視
  END;

  RETURN rv || ' mode=' || bmode || ' dates=' || COALESCE(dates, '(なし: 全日処理済み)') || ' alerts=' || n;
END;
$$;

-- =====================================================================
-- 5. T10 / T11: 判定
--    METHOD = 'decision' : snowflake-decision(T10)
--    METHOD = 'llm'      : 汎用LLM + 構造化出力(T11 フォールバック)
--    解析できた行が1件もない場合も失敗扱い(= フォールバックに回す)
-- =====================================================================
CREATE OR REPLACE PROCEDURE SP_DECIDE(METHOD VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  forced_failure EXCEPTION (-20001, 'シナリオ decision_down による強制失敗');
  all_unparsed   EXCEPTION (-20002, '判定結果を1件も解析できなかった');
  bad_method     EXCEPTION (-20009, 'METHOD は decision か llm を指定する');
  force_flag FLOAT;
  n_total    NUMBER DEFAULT 0;
  n_null     NUMBER DEFAULT 0;
BEGIN
  SELECT COALESCE(CFG('force_decision_failure'), 0) INTO :force_flag;
  IF (METHOD = 'decision' AND force_flag >= 1) THEN
    RAISE forced_failure;
  END IF;

  DELETE FROM DECISION_RESULTS WHERE ALERT_ID IN (SELECT ALERT_ID FROM CURRENT_BATCH);

  IF (METHOD = 'decision') THEN
    INSERT INTO DECISION_RESULTS
      (ALERT_ID, DECISION_MODEL, CAUSE, CAUSE_CONFIDENCE, CAUSE_PROBS, NEEDS_INVESTIGATION_PROB, RAW)
    WITH d AS (
      SELECT
        a.ALERT_ID,
        TRY_PARSE_JSON(TO_VARCHAR(AI_COMPLETE(
          model  => 'snowflake-decision',
          prompt => TO_JSON({
            'state': a.ALERT_TEXT,
            'questions': {
              'cause': {
                'type': 'choice',
                'instructions': '需要予測が外れた主な原因はどれか',
                'criteria': {
                  'promo':   '販促・キャンペーンの実施で需要が増えた',
                  'weather': '猛暑や豪雨など天候で需要が増減した',
                  'stock':   '欠品・在庫不足で実績が抑えられた',
                  'unknown': 'アラート本文からは原因を特定できない'
                }
              },
              'needs_investigation': {
                'type': 'noul',
                'instructions': 'アラート本文だけでは原因を確定できず、追加データの調査が必要である'
              }
            }
          })
        ))) AS j
      FROM FORECAST_ALERTS a
      JOIN CURRENT_BATCH b ON b.ALERT_ID = a.ALERT_ID
    )
    SELECT ALERT_ID, 'snowflake-decision',
           j:answers:cause:choice::STRING,
           j:answers:cause:confidence::FLOAT,
           j:answers:cause:probabilities,
           j:answers:needs_investigation:noul::FLOAT,
           j
    FROM d;

  ELSEIF (METHOD = 'llm') THEN
    INSERT INTO DECISION_RESULTS
      (ALERT_ID, DECISION_MODEL, CAUSE, CAUSE_CONFIDENCE, CAUSE_PROBS, NEEDS_INVESTIGATION_PROB, RAW)
    WITH d AS (
      SELECT
        a.ALERT_ID,
        TRY_PARSE_JSON(TO_VARCHAR(AI_COMPLETE(
          model  => 'claude-sonnet-5',
          prompt => '次の需要予測アラートを読み、予測が外れた主な原因を分類してください。'
                 || 'promo=販促・キャンペーン、weather=猛暑や豪雨などの天候、stock=欠品・在庫不足、'
                 || 'unknown=本文からは特定できない。confidence は分類の確からしさ(0〜1)、'
                 || 'needs_investigation_prob は本文だけでは確定できず追加調査が必要な確率(0〜1)。'
                 || ' アラート: ' || a.ALERT_TEXT,
          model_parameters => {'temperature': 0},
          response_format => {
            'type': 'json',
            'schema': {
              'type': 'object',
              'properties': {
                'cause': {'type': 'string', 'enum': ['promo', 'weather', 'stock', 'unknown']},
                'confidence': {'type': 'number'},
                'needs_investigation_prob': {'type': 'number'}
              },
              'required': ['cause', 'confidence', 'needs_investigation_prob']
            }
          }
        ))) AS j0
      FROM FORECAST_ALERTS a
      JOIN CURRENT_BATCH b ON b.ALERT_ID = a.ALERT_ID
    ),
    n AS (
      SELECT ALERT_ID, COALESCE(j0:structured_output[0]:raw_message, j0) AS j, j0 FROM d
    )
    SELECT ALERT_ID, 'llm-fallback',
           j:cause::STRING, j:confidence::FLOAT, NULL,
           j:needs_investigation_prob::FLOAT, j0
    FROM n;

  ELSE
    RAISE bad_method;
  END IF;

  SELECT COUNT(*), COUNT_IF(d.CAUSE IS NULL) INTO :n_total, :n_null
  FROM DECISION_RESULTS d JOIN CURRENT_BATCH b ON b.ALERT_ID = d.ALERT_ID;

  IF (n_total > 0 AND n_null = n_total) THEN
    RAISE all_unparsed;
  END IF;

  RETURN METHOD || ': rows=' || n_total || ' unparsed=' || n_null;
END;
$$;

-- =====================================================================
-- 6. T20: ルーティング
--    戻り値: ALL_AUTO       (エージェント不要)
--            AGENT          (エージェント対象が上限以内)
--            AGENT_OVERFLOW (上限超過。上位 agent_max_rows 件だけ調査し、残りは人手へ)
-- =====================================================================
CREATE OR REPLACE PROCEDURE SP_ROUTE()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  n_total  NUMBER DEFAULT 0;
  n_agent  NUMBER DEFAULT 0;
  max_rows FLOAT;
  rv       VARCHAR;
BEGIN
  DELETE FROM ROUTED_ALERTS WHERE ALERT_ID IN (SELECT ALERT_ID FROM CURRENT_BATCH);

  INSERT INTO ROUTED_ALERTS
    (ALERT_ID, ALERT_TEXT, ERROR_RATE, CAUSE, CAUSE_CONFIDENCE, NEEDS_INVESTIGATION_PROB, ROUTE, AGENT_PRIORITY)
  WITH r AS (
    SELECT
      a.ALERT_ID, a.ALERT_TEXT, a.ERROR_RATE,
      d.CAUSE, d.CAUSE_CONFIDENCE, d.NEEDS_INVESTIGATION_PROB,
      CASE
        WHEN d.CAUSE IS NOT NULL
         AND d.CAUSE <> 'unknown'
         AND d.CAUSE_CONFIDENCE >= CFG('auto_conf_min')
         AND d.NEEDS_INVESTIGATION_PROB < CFG('auto_inv_max')
          THEN 'auto'
        ELSE 'agent'
      END AS ROUTE
    FROM FORECAST_ALERTS a
    JOIN CURRENT_BATCH b ON b.ALERT_ID = a.ALERT_ID
    LEFT JOIN DECISION_RESULTS d ON d.ALERT_ID = a.ALERT_ID
  )
  SELECT r.*,
         IFF(ROUTE = 'agent',
             ROW_NUMBER() OVER (PARTITION BY ROUTE ORDER BY ABS(ERROR_RATE) DESC, ALERT_ID),
             NULL)
  FROM r;

  SELECT COUNT(*), COUNT_IF(r.ROUTE = 'agent') INTO :n_total, :n_agent
  FROM ROUTED_ALERTS r JOIN CURRENT_BATCH b ON b.ALERT_ID = r.ALERT_ID;
  SELECT CFG('agent_max_rows') INTO :max_rows;

  rv := CASE WHEN n_agent = 0 THEN 'ALL_AUTO'
             WHEN n_agent <= max_rows THEN 'AGENT'
             ELSE 'AGENT_OVERFLOW' END;
  BEGIN
    CALL SYSTEM$SET_RETURN_VALUE(:rv);
  EXCEPTION
    WHEN OTHER THEN NULL;
  END;

  RETURN rv || ' total=' || n_total || ' agent=' || n_agent || ' max=' || max_rows;
END;
$$;

-- =====================================================================
-- 7. T30: エージェント調査(優先度 <= agent_max_rows の行だけ)
--    行単位の失敗は記録して続行。失敗率が agent_error_max を超えたらタスクを失敗させる
-- =====================================================================
CREATE OR REPLACE PROCEDURE SP_RUN_AGENT_BATCH()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  forced_failure  EXCEPTION (-20003, 'シナリオ agent_down による強制失敗');
  too_many_errors EXCEPTION (-20004, 'エージェント呼び出しの失敗率が上限を超えた');
  force_flag FLOAT;
  err_max    FLOAT;
  n_ok       NUMBER DEFAULT 0;
  n_err      NUMBER DEFAULT 0;
  aid        NUMBER;
  body       VARCHAR;
  resp       VARCHAR;
  t0         TIMESTAMP_LTZ;
  c1 CURSOR FOR
    SELECT
      r.ALERT_ID,
      TO_JSON(OBJECT_CONSTRUCT(
        'messages', ARRAY_CONSTRUCT(OBJECT_CONSTRUCT(
          'role', 'user',
          'content', ARRAY_CONSTRUCT(OBJECT_CONSTRUCT(
            'type', 'text',
            'text', '次の需要予測アラートの原因を調査してください。' || r.ALERT_TEXT
          ))
        ))
      )) AS REQUEST_BODY
    FROM ROUTED_ALERTS r
    JOIN CURRENT_BATCH b ON b.ALERT_ID = r.ALERT_ID
    WHERE r.ROUTE = 'agent'
      AND r.AGENT_PRIORITY <= CFG('agent_max_rows')
    ORDER BY r.AGENT_PRIORITY;
BEGIN
  SELECT COALESCE(CFG('force_agent_failure'), 0), COALESCE(CFG('agent_error_max'), 0.5)
    INTO :force_flag, :err_max;
  IF (force_flag >= 1) THEN
    RAISE forced_failure;
  END IF;

  DELETE FROM AGENT_RESULTS WHERE ALERT_ID IN (SELECT ALERT_ID FROM CURRENT_BATCH);

  FOR rec IN c1 DO
    aid  := rec.ALERT_ID;
    body := rec.REQUEST_BODY;
    t0   := CURRENT_TIMESTAMP();
    BEGIN
      resp := (SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN(
                        'DECISION_PIPE_DB.DEMO.DEMAND_ALERT_AGENT', :body));

      INSERT INTO AGENT_RESULTS
        (ALERT_ID, STATUS, ANSWER_TEXT, AGENT_CAUSE, AGENT_EVIDENCE, RAW_RESPONSE, ELAPSED_MS)
      WITH p AS (SELECT TRY_PARSE_JSON(:resp) AS j),
      t AS (
        SELECT LISTAGG(f.value:text::STRING, '\n') WITHIN GROUP (ORDER BY f.index) AS answer
        FROM p, LATERAL FLATTEN(INPUT => p.j:content) f
        WHERE f.value:type::STRING = 'text'
      ),
      js AS (
        SELECT TRY_PARSE_JSON(REGEXP_SUBSTR(t.answer, '\\{[^{}]*"cause"[^{}]*\\}')) AS k
        FROM t
      )
      SELECT :aid, 'ok', t.answer,
             LOWER(js.k:cause::STRING), js.k:evidence::STRING,
             p.j, DATEDIFF('millisecond', :t0, CURRENT_TIMESTAMP())
      FROM p, t, js;

      n_ok := n_ok + 1;
    EXCEPTION
      WHEN OTHER THEN
        INSERT INTO AGENT_RESULTS (ALERT_ID, STATUS, ERROR_MESSAGE, ELAPSED_MS)
        VALUES (:aid, 'error', :SQLERRM, DATEDIFF('millisecond', :t0, CURRENT_TIMESTAMP()));
        n_err := n_err + 1;
    END;
  END FOR;

  IF (n_ok + n_err > 0 AND n_err / (n_ok + n_err) > err_max) THEN
    RAISE too_many_errors;
  END IF;

  RETURN 'ok=' || n_ok || ' error=' || n_err;
END;
$$;

-- =====================================================================
-- 8. T31 / T35 / T50: 人手レビューキューへの投入
--    KIND = 'overflow'     : 上限超過で調査しなかった行(T31)
--    KIND = 'agent_failed' : T30 が失敗したときの退避(T35)
--    KIND = 'final'        : 最終結果で human になった行(T50)
--    同じアラートは1回だけ投入する(先に入った理由を残す)
-- =====================================================================
CREATE OR REPLACE PROCEDURE SP_ENQUEUE_REVIEW(KIND VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  bad_mode EXCEPTION (-20010, 'KIND は overflow / agent_failed / final のいずれか');
  n NUMBER DEFAULT 0;
  msg VARCHAR;
BEGIN
  IF (KIND = 'overflow') THEN
    MERGE INTO HUMAN_REVIEW_QUEUE q
    USING (
      SELECT r.ALERT_ID, 'overflow' AS REASON, r.ALERT_TEXT
      FROM ROUTED_ALERTS r JOIN CURRENT_BATCH b ON b.ALERT_ID = r.ALERT_ID
      WHERE r.ROUTE = 'agent' AND r.AGENT_PRIORITY > CFG('agent_max_rows')
    ) s ON q.ALERT_ID = s.ALERT_ID
    WHEN NOT MATCHED THEN INSERT (ALERT_ID, REASON, SOURCE_TASK, ALERT_TEXT)
      VALUES (s.ALERT_ID, s.REASON, 'T31_OVERFLOW_TO_HUMAN', s.ALERT_TEXT);

  ELSEIF (KIND = 'agent_failed') THEN
    MERGE INTO HUMAN_REVIEW_QUEUE q
    USING (
      SELECT r.ALERT_ID, 'agent_failed' AS REASON, r.ALERT_TEXT
      FROM ROUTED_ALERTS r JOIN CURRENT_BATCH b ON b.ALERT_ID = r.ALERT_ID
      WHERE r.ROUTE = 'agent'
    ) s ON q.ALERT_ID = s.ALERT_ID
    WHEN NOT MATCHED THEN INSERT (ALERT_ID, REASON, SOURCE_TASK, ALERT_TEXT)
      VALUES (s.ALERT_ID, s.REASON, 'T35_AGENT_FAILED', s.ALERT_TEXT);

  ELSEIF (KIND = 'final') THEN
    MERGE INTO HUMAN_REVIEW_QUEUE q
    USING (
      SELECT f.ALERT_ID, f.HUMAN_REASON AS REASON, a.ALERT_TEXT
      FROM FINAL_RESULTS f
      JOIN CURRENT_BATCH b ON b.ALERT_ID = f.ALERT_ID
      JOIN FORECAST_ALERTS a ON a.ALERT_ID = f.ALERT_ID
      WHERE f.FINAL_ROUTE = 'human'
    ) s ON q.ALERT_ID = s.ALERT_ID
    WHEN NOT MATCHED THEN INSERT (ALERT_ID, REASON, SOURCE_TASK, ALERT_TEXT)
      VALUES (s.ALERT_ID, s.REASON, 'T50_REVIEW_QUEUE', s.ALERT_TEXT);

    -- 通知を送る場合は通知統合を作成し、下のコメントを外す
    -- CALL SYSTEM$SEND_SNOWFLAKE_NOTIFICATION(
    --   SNOWFLAKE.NOTIFICATION.TEXT_PLAIN('人手レビュー待ちのアラートがあります'),
    --   SNOWFLAKE.NOTIFICATION.INTEGRATION('<email_integration_name>'));
  ELSE
    RAISE bad_mode;
  END IF;

  n := SQLROWCOUNT;
  msg := KIND || ': enqueued=' || n;
  CALL SP_LOG_EVENT(:KIND, 'enqueue', :msg);
  RETURN msg;
END;
$$;

-- =====================================================================
-- 9. T40: 品質チェックと最終結果の確定
--    品質チェックは snowflake-decision を試し、失敗・解析不能なら汎用LLMに切り替える
--    戻り値: REVIEW_NEEDED(人手行あり) / OK
-- =====================================================================
CREATE OR REPLACE PROCEDURE SP_FINALIZE_RESULTS()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  use_dec  FLOAT;
  qmin     FLOAT;
  maxr     FLOAT;
  qmodel   VARCHAR DEFAULT 'none';
  n_q      NUMBER DEFAULT 0;
  n_scored NUMBER DEFAULT 0;
  n_total  NUMBER DEFAULT 0;
  n_human  NUMBER DEFAULT 0;
  rv       VARCHAR;
BEGIN
  SELECT COALESCE(CFG('use_decision_for_quality'), 1), CFG('quality_min'), CFG('agent_max_rows')
    INTO :use_dec, :qmin, :maxr;

  CREATE OR REPLACE TEMPORARY TABLE TMP_QUALITY (ALERT_ID NUMBER, SCORE FLOAT, RAW VARIANT);

  -- (1) snowflake-decision で根拠スコアを付ける
  IF (use_dec >= 1) THEN
    BEGIN
      INSERT INTO TMP_QUALITY
      SELECT ALERT_ID, qj:answers:grounded:score::FLOAT, qj
      FROM (
        SELECT
          ar.ALERT_ID,
          TRY_PARSE_JSON(TO_VARCHAR(AI_COMPLETE(
            model  => 'snowflake-decision',
            prompt => TO_JSON({
              'state': 'アラート: ' || r.ALERT_TEXT || ' / 調査結果: ' || ar.ANSWER_TEXT,
              'questions': {
                'grounded': {
                  'type': 'score',
                  'instructions': '調査結果の原因判定は、確認したデータの数値によって裏付けられているか',
                  'criteria': ['根拠がない、または推測のみ', '一部の根拠のみ', 'データの数値で明確に裏付けられている']
                }
              }
            })
          ))) AS qj
        FROM AGENT_RESULTS ar
        JOIN CURRENT_BATCH b  ON b.ALERT_ID = ar.ALERT_ID
        JOIN ROUTED_ALERTS r  ON r.ALERT_ID = ar.ALERT_ID
        WHERE ar.STATUS = 'ok' AND ar.AGENT_CAUSE IS NOT NULL
      ) qd;
      SELECT COUNT(*), COUNT(SCORE) INTO :n_q, :n_scored FROM TMP_QUALITY;
      qmodel := IFF(n_q > 0 AND n_scored = 0, 'decision_unparsed', 'snowflake-decision');
    EXCEPTION
      WHEN OTHER THEN qmodel := 'decision_failed';
    END;
  END IF;

  -- (2) フォールバック: 汎用LLM
  IF (qmodel <> 'snowflake-decision') THEN
    DELETE FROM TMP_QUALITY;
    INSERT INTO TMP_QUALITY
    SELECT ALERT_ID,
           COALESCE(j0:structured_output[0]:raw_message:score, j0:score)::FLOAT,
           j0
    FROM (
      SELECT
        ar.ALERT_ID,
        TRY_PARSE_JSON(TO_VARCHAR(AI_COMPLETE(
          model  => 'claude-sonnet-5',
          prompt => '次の調査結果の原因判定が、確認したデータの数値で裏付けられているかを 0〜2 で採点してください。'
                 || '0=根拠がない/推測のみ、1=一部の根拠のみ、2=数値で明確に裏付けられている。'
                 || ' アラート: ' || r.ALERT_TEXT || ' / 調査結果: ' || ar.ANSWER_TEXT,
          model_parameters => {'temperature': 0},
          response_format => {
            'type': 'json',
            'schema': {
              'type': 'object',
              'properties': {'score': {'type': 'number'}},
              'required': ['score']
            }
          }
        ))) AS j0
      FROM AGENT_RESULTS ar
      JOIN CURRENT_BATCH b ON b.ALERT_ID = ar.ALERT_ID
      JOIN ROUTED_ALERTS r ON r.ALERT_ID = ar.ALERT_ID
      WHERE ar.STATUS = 'ok' AND ar.AGENT_CAUSE IS NOT NULL
    ) ql;
    qmodel := 'llm' || IFF(qmodel = 'none', '', ' (' || qmodel || ')');
  END IF;

  -- (3) 最終結果
  DELETE FROM FINAL_RESULTS WHERE ALERT_ID IN (SELECT ALERT_ID FROM CURRENT_BATCH);

  INSERT INTO FINAL_RESULTS
    (ALERT_ID, ROUTE, FINAL_ROUTE, FINAL_CAUSE, QUALITY_SCORE, QUALITY_RAW, HUMAN_REASON, QUALITY_MODEL)
  SELECT
    r.ALERT_ID,
    r.ROUTE,
    CASE WHEN r.ROUTE = 'auto' THEN 'auto'
         WHEN q.SCORE >= :qmin THEN 'agent'
         ELSE 'human' END,
    CASE WHEN r.ROUTE = 'auto' THEN r.CAUSE
         WHEN q.SCORE >= :qmin THEN ar.AGENT_CAUSE
         ELSE NULL END,
    q.SCORE,
    q.RAW,
    CASE WHEN r.ROUTE = 'auto' OR q.SCORE >= :qmin THEN NULL
         WHEN r.AGENT_PRIORITY > :maxr THEN 'overflow'
         WHEN ar.ALERT_ID IS NULL     THEN 'agent_not_run'
         WHEN ar.STATUS = 'error'     THEN 'agent_error'
         WHEN ar.AGENT_CAUSE IS NULL  THEN 'agent_unparsed'
         ELSE 'low_quality' END,
    IFF(r.ROUTE = 'agent', :qmodel, NULL)
  FROM ROUTED_ALERTS r
  JOIN CURRENT_BATCH b      ON b.ALERT_ID = r.ALERT_ID
  LEFT JOIN AGENT_RESULTS ar ON ar.ALERT_ID = r.ALERT_ID
  LEFT JOIN TMP_QUALITY q    ON q.ALERT_ID = r.ALERT_ID;

  SELECT COUNT(*), COUNT_IF(f.FINAL_ROUTE = 'human') INTO :n_total, :n_human
  FROM FINAL_RESULTS f JOIN CURRENT_BATCH b ON b.ALERT_ID = f.ALERT_ID;

  rv := IFF(n_human > 0, 'REVIEW_NEEDED', 'OK');
  BEGIN
    CALL SYSTEM$SET_RETURN_VALUE(:rv);
  EXCEPTION
    WHEN OTHER THEN NULL;
  END;

  RETURN rv || ' total=' || n_total || ' human=' || n_human || ' quality_model=' || qmodel;
END;
$$;

-- =====================================================================
-- 10. T99 (ファイナライザー): 実行サマリと通った経路を記録し、バッチを処理済みにする
--     途中のタスクが失敗しても必ず実行される
-- =====================================================================
CREATE OR REPLACE PROCEDURE SP_RUN_SUMMARY()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  gid      VARCHAR DEFAULT NULL;
  dates    VARCHAR;
  n_alerts NUMBER DEFAULT 0;
  n_final  NUMBER DEFAULT 0;
  run_status VARCHAR;
BEGIN
  BEGIN
    SELECT SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_GRAPH_RUN_GROUP_ID') INTO :gid;
  EXCEPTION
    WHEN OTHER THEN gid := NULL;
  END;

  -- (1) 今回の実行で各タスクがどう終わったか(SUCCEEDED / FAILED / SKIPPED と戻り値)
  IF (gid IS NOT NULL) THEN
    BEGIN
      INSERT INTO RUN_TASK_STATES
        (RUN_GROUP_ID, TASK_NAME, STATE, RETURN_VALUE, ERROR_MESSAGE, QUERY_START_TIME, COMPLETED_TIME)
      SELECT GRAPH_RUN_GROUP_ID, NAME, STATE, RETURN_VALUE, ERROR_MESSAGE, QUERY_START_TIME, COMPLETED_TIME
      FROM TABLE(DECISION_PIPE_DB.INFORMATION_SCHEMA.TASK_HISTORY(
             SCHEDULED_TIME_RANGE_START => DATEADD('day', -1, CURRENT_TIMESTAMP()),
             RESULT_LIMIT => 10000))
      WHERE GRAPH_RUN_GROUP_ID = :gid;
    EXCEPTION
      WHEN OTHER THEN NULL;   -- 取得できなくてもサマリは残す
    END;
  END IF;

  -- (2) バッチの完了判定
  SELECT LISTAGG(TO_VARCHAR(SALES_DATE, 'YYYY-MM-DD'), ',') WITHIN GROUP (ORDER BY SALES_DATE)
    INTO :dates
  FROM CURRENT_BATCH_DATES;

  SELECT COUNT(b.ALERT_ID), COUNT(f.ALERT_ID) INTO :n_alerts, :n_final
  FROM CURRENT_BATCH b LEFT JOIN FINAL_RESULTS f ON f.ALERT_ID = b.ALERT_ID;

  run_status := CASE WHEN n_alerts = 0 THEN 'no_alerts'
                 WHEN n_final = n_alerts THEN 'complete'
                 ELSE 'incomplete' END;

  -- (3) サマリ(正解ラベルとの突合を含む)
  INSERT INTO RUN_SUMMARY
    (RUN_GROUP_ID, BATCH_DATES, N_ALERTS, DECISION_MODEL, QUALITY_MODEL,
     N_AUTO, N_AGENT, N_HUMAN, AUTOMATED_ACC, STATUS)
  SELECT
    :gid, :dates, COUNT(b.ALERT_ID),
    MAX(d.DECISION_MODEL), MAX(f.QUALITY_MODEL),
    COUNT_IF(f.FINAL_ROUTE = 'auto'),
    COUNT_IF(f.FINAL_ROUTE = 'agent'),
    COUNT_IF(f.FINAL_ROUTE = 'human'),
    AVG(IFF(f.FINAL_ROUTE IN ('auto', 'agent'), IFF(f.FINAL_CAUSE = l.TRUE_CAUSE, 1, 0), NULL)),
    :run_status
  FROM CURRENT_BATCH b
  LEFT JOIN FINAL_RESULTS f    ON f.ALERT_ID = b.ALERT_ID
  LEFT JOIN DECISION_RESULTS d ON d.ALERT_ID = b.ALERT_ID
  LEFT JOIN ALERT_LABELS l     ON l.ALERT_ID = b.ALERT_ID;

  -- (4) 完了したバッチだけ処理済みにする(incomplete は次回もう一度処理する)
  IF (run_status IN ('complete', 'no_alerts')) THEN
    INSERT INTO ALERT_BATCH_STATE (SALES_DATE, RUN_GROUP_ID)
    SELECT d.SALES_DATE, :gid FROM CURRENT_BATCH_DATES d
    WHERE NOT EXISTS (SELECT 1 FROM ALERT_BATCH_STATE s WHERE s.SALES_DATE = d.SALES_DATE);
  END IF;

  RETURN run_status || ' dates=' || COALESCE(dates, '-') || ' alerts=' || n_alerts || ' finalized=' || n_final;
END;
$$;

-- =====================================================================
-- 11. 検証シナリオの切り替え
--   normal        : 通常
--   decision_down : T10 を強制失敗 → T11(フォールバック)が動く
--   agent_down    : T30 を強制失敗 → T35(退避)が動く
--   overflow      : agent_max_rows = 1 → T31(上限超過の人手送り)が動く
--   drained       : 全日を処理済みにする → 次回は NO_ALERTS で T05 だけが動く
--   reset         : 結果をすべて消して最初の日からやり直す(設定は normal に戻す)
-- =====================================================================
CREATE OR REPLACE PROCEDURE SP_SET_SCENARIO(NAME VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  bad_name EXCEPTION (-20011, 'normal / decision_down / agent_down / overflow / drained / reset のいずれかを指定する');
  s VARCHAR;
BEGIN
  s := LOWER(NAME);
  IF (s NOT IN ('normal', 'decision_down', 'agent_down', 'overflow', 'drained', 'reset')) THEN
    RAISE bad_name;
  END IF;

  IF (s = 'reset') THEN
    TRUNCATE TABLE ALERT_BATCH_STATE;
    TRUNCATE TABLE CURRENT_BATCH_DATES;
    TRUNCATE TABLE CURRENT_BATCH;
    TRUNCATE TABLE DECISION_RESULTS;
    TRUNCATE TABLE ROUTED_ALERTS;
    TRUNCATE TABLE AGENT_RESULTS;
    TRUNCATE TABLE FINAL_RESULTS;
    TRUNCATE TABLE HUMAN_REVIEW_QUEUE;
    TRUNCATE TABLE PIPELINE_EVENTS;
    TRUNCATE TABLE RUN_SUMMARY;
    TRUNCATE TABLE RUN_TASK_STATES;
    s := 'normal';
  END IF;

  IF (s = 'drained') THEN
    INSERT INTO ALERT_BATCH_STATE (SALES_DATE, RUN_GROUP_ID)
    SELECT c.SALES_DATE, 'scenario:drained' FROM BATCH_CALENDAR c
    WHERE NOT EXISTS (SELECT 1 FROM ALERT_BATCH_STATE x WHERE x.SALES_DATE = c.SALES_DATE);
  END IF;

  UPDATE PIPELINE_CONFIG
     SET VALUE = CASE KEY
                   WHEN 'force_decision_failure' THEN IFF(:s = 'decision_down', 1, 0)
                   WHEN 'force_agent_failure'    THEN IFF(:s = 'agent_down', 1, 0)
                   WHEN 'agent_max_rows'         THEN IFF(:s = 'overflow', 1, 5)
                 END
   WHERE KEY IN ('force_decision_failure', 'force_agent_failure', 'agent_max_rows');

  CALL SP_LOG_EVENT('SCENARIO', 'set', :s);
  RETURN 'scenario=' || s;
END;
$$;

-- =====================================================================
-- 12. 確認用ビュー
-- =====================================================================
-- 実行ごとに通った経路(SKIPPED も含めて並べる)
CREATE OR REPLACE VIEW V_RUN_PATH AS
SELECT
  s.LOGGED_AT,
  s.RUN_GROUP_ID,
  s.BATCH_DATES,
  s.STATUS,
  LISTAGG(
    SPLIT_PART(t.TASK_NAME, '.', -1) || '=' || t.STATE
      || IFF(t.RETURN_VALUE IS NOT NULL, '(' || t.RETURN_VALUE || ')', ''),
    '  ')
    WITHIN GROUP (ORDER BY t.QUERY_START_TIME NULLS LAST, t.TASK_NAME) AS PATH
FROM RUN_SUMMARY s
LEFT JOIN RUN_TASK_STATES t ON t.RUN_GROUP_ID = s.RUN_GROUP_ID
GROUP BY s.LOGGED_AT, s.RUN_GROUP_ID, s.BATCH_DATES, s.STATUS;

-- 1日あたりのアラート件数(どの日がどの分岐になりそうかの目安)
CREATE OR REPLACE VIEW V_BATCH_PREVIEW AS
SELECT c.SALES_DATE,
       COUNT(a.ALERT_ID)                     AS N_ALERTS,
       COUNT_IF(NOT a.HAS_CONTEXT)           AS N_NO_CONTEXT,
       IFF(s.SALES_DATE IS NULL, FALSE, TRUE) AS PROCESSED
FROM BATCH_CALENDAR c
LEFT JOIN FORECAST_ALERTS a   ON a.SALES_DATE = c.SALES_DATE
LEFT JOIN ALERT_BATCH_STATE s ON s.SALES_DATE = c.SALES_DATE
GROUP BY c.SALES_DATE, s.SALES_DATE;

SELECT * FROM V_BATCH_PREVIEW ORDER BY SALES_DATE;
