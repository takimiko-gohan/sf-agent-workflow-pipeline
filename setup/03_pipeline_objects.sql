-- =====================================================================
-- 03_pipeline_objects.sql
-- パイプラインの設定値と、各カードが読み書きするテーブル・確認用ビュー
-- (処理ロジックはすべて pipeline/ のカード側に書いている。プロシージャは使わない)
-- =====================================================================

USE ROLE DECISION_PIPE_ROLE;
USE WAREHOUSE DECISION_PIPE_WH;
USE SCHEMA DECISION_PIPE_DB.SUPPORT;

-- =====================================================================
-- 1. 設定値(閾値はここを UPDATE して調整する)
-- =====================================================================
CREATE OR REPLACE TABLE PIPELINE_CONFIG (
  KEY   VARCHAR,
  VALUE FLOAT,
  NOTE  VARCHAR
);
INSERT INTO PIPELINE_CONFIG VALUES
  ('human_min',                0.50, '要担当者の確率がこれ以上なら、最初から人手に回す'),
  ('auto_conf_min',            0.80, 'ヘルプ記事の選択の確信度がこれ以上なら、定型回答の候補にする'),
  ('auto_data_max',            0.30, '顧客データが必要な確率がこれ未満なら、定型回答にする'),
  ('agent_max_rows',           5,    '1回の実行でエージェントに回す上限件数(超過分は人手へ)'),
  ('agent_error_max',          0.50, 'エージェント呼び出しの失敗率がこれを超えたら T30 を失敗扱いにする'),
  ('quality_min',              1.20, '回答の根拠スコア(0〜2)がこれ以上なら送信可'),
  ('resolves_min',             0.50, '質問に答えている確率がこれ以上なら送信可'),
  ('risk_max',                 0.50, '承認が必要な内容を含む確率がこれ未満なら送信可'),
  ('translate_for_decider',    1,    '1=decider-2b に渡す前に AI_TRANSLATE で英訳する / 0=日本語のまま渡す(翻訳の効果を比べる用)'),
  ('force_classify_failure',   0,    '1 にすると decider-2b での分類(T10)を強制失敗させる(フォールバック検証用)'),
  ('force_agent_failure',      0,    '1 にするとエージェント(T30)を強制失敗させる'),
  ('force_quality_failure',    0,    '1 にすると decider-2b での品質チェック(T41)を強制失敗させる');

CREATE OR REPLACE FUNCTION CFG(K VARCHAR)
RETURNS FLOAT
AS
$$
  SELECT MAX(VALUE) FROM DECISION_PIPE_DB.SUPPORT.PIPELINE_CONFIG WHERE KEY = K
$$;

-- =====================================================================
-- 2. バッチ管理(1日分の受付チケットを1バッチとして処理する)
-- =====================================================================
CREATE OR REPLACE TABLE BATCH_CALENDAR AS
SELECT DATEADD(day, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, '2026-10-02'::DATE) AS RECEIVED_DATE
FROM TABLE(GENERATOR(ROWCOUNT => 30));

CREATE OR REPLACE TABLE BATCH_STATE (
  RECEIVED_DATE DATE,
  RUN_GROUP_ID  VARCHAR,
  PROCESSED_AT  TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
) COMMENT = '処理済みの受付日';

CREATE OR REPLACE TABLE CURRENT_BATCH_DATES (RECEIVED_DATE DATE) COMMENT = '今回の実行で処理する受付日';
CREATE OR REPLACE TABLE CURRENT_BATCH (TICKET_ID VARCHAR, RECEIVED_DATE DATE) COMMENT = '今回の実行で処理するチケット';

-- =====================================================================
-- 3. 各ステップの出力
-- =====================================================================
CREATE OR REPLACE TABLE TICKET_TRANSLATIONS (
  TICKET_ID     VARCHAR,
  TEXT_EN       VARCHAR,       -- 問い合わせの英訳(失敗時は NULL)
  ERROR_MESSAGE VARCHAR,
  TRANSLATED_AT TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
) COMMENT = 'T07: 問い合わせの英訳(decider-2b への入力用)';

CREATE OR REPLACE TABLE KB_TRANSLATIONS (
  KB_ID         VARCHAR,
  TITLE_EN      VARCHAR,       -- ヘルプ記事タイトルの英訳(decider-2b の選択肢に使う)
  TRANSLATED_AT TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
) COMMENT = 'T07: ヘルプ記事タイトルの英訳(未翻訳の記事だけ翻訳して蓄積する)';

CREATE OR REPLACE TABLE CLASSIFY_RESULTS (
  TICKET_ID         VARCHAR,
  CLASSIFY_MODEL    VARCHAR,
  INPUT_LANG        VARCHAR,     -- decider-2b に渡した本文の言語(en = 英訳 / ja = 日本語のまま)
  CATEGORY          VARCHAR,
  CATEGORY_CONF     FLOAT,
  KB_ID             VARCHAR,     -- 'none' = 該当記事なし
  KB_CONF           FLOAT,
  HUMAN_PROB        FLOAT,       -- 担当者の対応が必要な確率
  ACCOUNT_DATA_PROB FLOAT,       -- 顧客データの確認が必要な確率
  RAW               VARIANT,
  CLASSIFIED_AT     TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
) COMMENT = 'T10/T11: 問い合わせの分類';

CREATE OR REPLACE TABLE ROUTED_TICKETS (
  TICKET_ID         VARCHAR,
  TICKET_TEXT       VARCHAR,
  RECEIVED_AT       TIMESTAMP_NTZ,
  CATEGORY          VARCHAR,
  KB_ID             VARCHAR,
  KB_CONF           FLOAT,
  HUMAN_PROB        FLOAT,
  ACCOUNT_DATA_PROB FLOAT,
  ROUTE             VARCHAR,     -- auto(ヘルプ記事で定型回答) / agent(エージェントで調査) / human(担当者)
  AGENT_PRIORITY    NUMBER,
  ROUTED_AT         TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
) COMMENT = 'T20: 振り分け結果';

CREATE OR REPLACE TABLE AGENT_RESULTS (
  TICKET_ID     VARCHAR,
  STATUS        VARCHAR,         -- ok / error
  ANSWER_TEXT   VARCHAR,         -- エージェントの最終回答(JSON行を含む)
  REPLY_TEXT    VARCHAR,         -- 顧客向け返信文(JSON行を除いたもの)
  RESOLUTION    VARCHAR,         -- answered / needs_human
  SOURCES       VARIANT,
  FACTS         VARCHAR,
  RAW_RESPONSE  VARIANT,
  ERROR_MESSAGE VARCHAR,
  ELAPSED_MS    NUMBER,
  CREATED_AT    TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
) COMMENT = 'T30: エージェントの回答案';

CREATE OR REPLACE TABLE AUTO_ANSWERS (
  TICKET_ID  VARCHAR,
  KB_ID      VARCHAR,
  REPLY_TEXT VARCHAR,
  MODEL      VARCHAR,
  CREATED_AT TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
) COMMENT = 'T40: ヘルプ記事にもとづく定型回答';

CREATE OR REPLACE TABLE QUALITY_CANDIDATES (
  TICKET_ID   VARCHAR,
  SRC         VARCHAR,           -- auto / agent
  TICKET_TEXT VARCHAR,
  REPLY_TEXT  VARCHAR,
  REFERENCE   VARCHAR,           -- 照合に使う参照情報(ヘルプ記事・顧客データの要約)
  CREATED_AT  TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
) COMMENT = 'T40: 品質チェックの対象(送信候補)';

CREATE OR REPLACE TABLE QUALITY_SCORES (
  TICKET_ID  VARCHAR,
  MODEL      VARCHAR,            -- decider-2b / llm-fallback
  INPUT_LANG VARCHAR,            -- decider-2b に渡した言語(en / ja)
  SCORE      FLOAT,              -- 根拠スコア(0〜2)
  RESOLVES   FLOAT,              -- 質問に答えている確率
  RISK       FLOAT,              -- 承認が必要な内容を含む確率
  RAW        VARIANT,
  SCORED_AT  TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
) COMMENT = 'T41/T42: 品質チェックの結果';

CREATE OR REPLACE TABLE FINAL_RESULTS (
  TICKET_ID      VARCHAR,
  ROUTE          VARCHAR,
  FINAL_ROUTE    VARCHAR,        -- auto / agent / human
  FINAL_CATEGORY VARCHAR,
  FINAL_REPLY    VARCHAR,        -- 送信可の返信文(human は NULL)
  DRAFT_REPLY    VARCHAR,        -- 人手に回した場合の下書き(あれば)
  QUALITY_SCORE  FLOAT,
  RESOLVES_PROB  FLOAT,
  RISK_PROB      FLOAT,
  QUALITY_RAW    VARIANT,
  HUMAN_REASON   VARCHAR,
  QUALITY_MODEL  VARCHAR,
  DECIDED_AT     TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
) COMMENT = 'T40: 最終結果';

CREATE OR REPLACE TABLE HUMAN_REVIEW_QUEUE (
  TICKET_ID    VARCHAR,
  REASON       VARCHAR,          -- classified_human / overflow / agent_failed / agent_escalated / low_quality など
  SOURCE_TASK  VARCHAR,
  TICKET_TEXT  VARCHAR,
  DRAFT_REPLY  VARCHAR,
  HANDOFF_NOTE VARCHAR,          -- 担当者向けの引き継ぎメモ(T50 で生成)
  STATUS       VARCHAR DEFAULT 'open',
  ENQUEUED_AT  TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
) COMMENT = '担当者の対応待ち';

CREATE OR REPLACE TABLE PIPELINE_EVENTS (
  LOGGED_AT    TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
  RUN_GROUP_ID VARCHAR,
  TASK         VARCHAR,
  EVENT        VARCHAR,
  DETAIL       VARCHAR
) COMMENT = '各カードのイベントログ';

CREATE OR REPLACE TABLE RUN_SUMMARY (
  LOGGED_AT           TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
  RUN_GROUP_ID        VARCHAR,
  BATCH_DATES         VARCHAR,
  N_TICKETS           NUMBER,
  CLASSIFY_MODEL      VARCHAR,
  QUALITY_MODEL       VARCHAR,
  N_AUTO              NUMBER,
  N_AGENT             NUMBER,
  N_HUMAN             NUMBER,
  N_UNSAFE_AUTOMATION NUMBER,    -- 正解は要担当者なのに自動で回答した件数(最重要)
  N_MISSED_AUTOMATION NUMBER,    -- 自動で回答できたのに人手に回した件数
  CATEGORY_ACC        FLOAT,
  STATUS              VARCHAR    -- complete / incomplete / no_tickets
) COMMENT = 'T99: 実行ごとのサマリ';

CREATE OR REPLACE TABLE RUN_TASK_STATES (
  RUN_GROUP_ID     VARCHAR,
  TASK_NAME        VARCHAR,
  STATE            VARCHAR,
  RETURN_VALUE     VARCHAR,
  ERROR_MESSAGE    VARCHAR,
  QUERY_START_TIME TIMESTAMP_LTZ,
  COMPLETED_TIME   TIMESTAMP_LTZ
) COMMENT = 'T99: その実行で各タスクがどう終わったか(通った経路)';

-- =====================================================================
-- 4. 確認用ビュー
-- =====================================================================
CREATE OR REPLACE VIEW V_RUN_PATH AS
SELECT
  s.LOGGED_AT, s.RUN_GROUP_ID, s.BATCH_DATES, s.STATUS,
  LISTAGG(
    SPLIT_PART(t.TASK_NAME, '.', -1) || '=' || t.STATE
      || IFF(t.RETURN_VALUE IS NOT NULL, '(' || t.RETURN_VALUE || ')', ''),
    '  ')
    WITHIN GROUP (ORDER BY t.QUERY_START_TIME NULLS LAST, t.TASK_NAME) AS PATH
FROM RUN_SUMMARY s
LEFT JOIN RUN_TASK_STATES t ON t.RUN_GROUP_ID = s.RUN_GROUP_ID
GROUP BY s.LOGGED_AT, s.RUN_GROUP_ID, s.BATCH_DATES, s.STATUS;

CREATE OR REPLACE VIEW V_BATCH_PREVIEW AS
SELECT c.RECEIVED_DATE,
       DAYNAME(c.RECEIVED_DATE)                     AS DOW,
       COUNT(t.TICKET_ID)                           AS N_TICKETS,
       IFF(MAX(s.RECEIVED_DATE) IS NULL, FALSE, TRUE) AS PROCESSED
FROM BATCH_CALENDAR c
LEFT JOIN SUPPORT_TICKETS t ON t.RECEIVED_AT::DATE = c.RECEIVED_DATE
LEFT JOIN BATCH_STATE s     ON s.RECEIVED_DATE = c.RECEIVED_DATE
GROUP BY c.RECEIVED_DATE;

-- 問い合わせと最終的な返信を並べて読む
CREATE OR REPLACE VIEW V_TICKET_RESULTS AS
SELECT
  t.TICKET_ID, t.RECEIVED_AT, t.COMPANY_NAME, t.FORM_CATEGORY, t.SUBJECT, t.BODY,
  r.CATEGORY, r.KB_ID, r.ROUTE,
  f.FINAL_ROUTE, f.HUMAN_REASON, f.QUALITY_SCORE, f.RESOLVES_PROB, f.RISK_PROB,
  f.FINAL_REPLY, f.DRAFT_REPLY,
  q.HANDOFF_NOTE,
  tr.TEXT_EN
FROM SUPPORT_TICKETS t
LEFT JOIN TICKET_TRANSLATIONS tr ON tr.TICKET_ID = t.TICKET_ID
LEFT JOIN ROUTED_TICKETS r     ON r.TICKET_ID = t.TICKET_ID
LEFT JOIN FINAL_RESULTS f      ON f.TICKET_ID = t.TICKET_ID
LEFT JOIN HUMAN_REVIEW_QUEUE q ON q.TICKET_ID = t.TICKET_ID;

SHOW TABLES IN SCHEMA DECISION_PIPE_DB.SUPPORT;
