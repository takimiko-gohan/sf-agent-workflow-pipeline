-- =====================================================================
-- 03_pipeline_objects.sql
-- パイプラインの各カードが読み書きするテーブル、設定値、
-- エージェント実行プロシージャを作成する
-- =====================================================================

USE ROLE DECISION_PIPE_ROLE;
USE WAREHOUSE DECISION_PIPE_WH;
USE SCHEMA DECISION_PIPE_DB.DEMO;

-- ---------- 設定値(閾値はここを UPDATE して調整する) ----------
CREATE OR REPLACE TABLE PIPELINE_CONFIG (
  KEY   VARCHAR PRIMARY KEY,
  VALUE FLOAT,
  NOTE  VARCHAR
);
INSERT INTO PIPELINE_CONFIG VALUES
  ('auto_conf_min',   0.80, 'cause の confidence がこれ以上なら自動確定の候補'),
  ('auto_inv_max',    0.30, '要調査確率がこれ未満なら自動確定'),
  ('agent_max_rows',  30,   '1回の実行でエージェントに回す最大件数(超過分は人手)'),
  ('quality_min',     1.20, 'エージェント回答の根拠スコア(0〜2)がこれ以上なら採用');

-- ---------- 各ステップの出力テーブル ----------
CREATE OR REPLACE TABLE DECISION_RESULTS (
  ALERT_ID                 NUMBER,
  DECISION_MODEL           VARCHAR,
  CAUSE                    VARCHAR,
  CAUSE_CONFIDENCE         FLOAT,
  CAUSE_PROBS              VARIANT,
  NEEDS_INVESTIGATION_PROB FLOAT,
  RAW                      VARIANT,
  DECIDED_AT               TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
) COMMENT = 'Step 10: 判定モデルの出力(正規化済み)';

CREATE OR REPLACE TABLE ROUTED_ALERTS (
  ALERT_ID                 NUMBER,
  ALERT_TEXT               VARCHAR,
  ERROR_RATE               NUMBER(6,3),
  CAUSE                    VARCHAR,
  CAUSE_CONFIDENCE         FLOAT,
  NEEDS_INVESTIGATION_PROB FLOAT,
  ROUTE                    VARCHAR,      -- auto / agent / human
  ROUTED_AT                TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
) COMMENT = 'Step 20: ルーティング結果';

CREATE OR REPLACE TABLE AGENT_RESULTS (
  ALERT_ID      NUMBER,
  STATUS        VARCHAR,                 -- ok / error
  ANSWER_TEXT   VARCHAR,
  AGENT_CAUSE   VARCHAR,
  AGENT_EVIDENCE VARCHAR,
  RAW_RESPONSE  VARIANT,
  ERROR_MESSAGE VARCHAR,
  ELAPSED_MS    NUMBER,
  CREATED_AT    TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
) COMMENT = 'Step 30: エージェントの調査結果';

CREATE OR REPLACE TABLE FINAL_RESULTS (
  ALERT_ID       NUMBER,
  ROUTE          VARCHAR,
  FINAL_ROUTE    VARCHAR,                -- auto / agent / human
  FINAL_CAUSE    VARCHAR,                -- 人手に回したものは NULL
  QUALITY_SCORE  FLOAT,
  QUALITY_RAW    VARIANT,
  DECIDED_AT     TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
) COMMENT = 'Step 40: 品質チェック後の最終結果';

CREATE OR REPLACE TABLE PIPELINE_RUN_LOG (
  LOGGED_AT TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
  METRIC    VARCHAR,
  DIM       VARCHAR,
  VALUE     FLOAT
) COMMENT = 'Step 50: 評価指標の履歴';

-- ---------- エージェント実行プロシージャ ----------
-- ROUTE = 'agent' の行を誤差の大きい順に最大 MAX_ROWS 件、1件ずつ DATA_AGENT_RUN で調査する。
-- MAX_ROWS に NULL を渡すと PIPELINE_CONFIG の agent_max_rows を使う。
-- 1件の失敗でパイプライン全体が止まらないよう、行ごとに例外を捕捉して記録する。
CREATE OR REPLACE PROCEDURE SP_RUN_AGENT_FOR_ALERTS(MAX_ROWS NUMBER)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  n_ok    NUMBER DEFAULT 0;
  n_err   NUMBER DEFAULT 0;
  aid     NUMBER;
  body    VARCHAR;
  resp    VARCHAR;
  t0      TIMESTAMP_LTZ;
  rs RESULTSET DEFAULT (
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
    WHERE r.ROUTE = 'agent'
      AND NOT EXISTS (SELECT 1 FROM AGENT_RESULTS a WHERE a.ALERT_ID = r.ALERT_ID)
    QUALIFY ROW_NUMBER() OVER (ORDER BY ABS(r.ERROR_RATE) DESC, r.ALERT_ID)
            <= COALESCE(:MAX_ROWS, (SELECT VALUE FROM PIPELINE_CONFIG WHERE KEY = 'agent_max_rows'))
  );
  cur CURSOR FOR rs;
BEGIN
  FOR rec IN cur DO
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
  RETURN 'ok=' || n_ok || ', error=' || n_err;
END;
$$;

SHOW TABLES IN SCHEMA DECISION_PIPE_DB.DEMO;
