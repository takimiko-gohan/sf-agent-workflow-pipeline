-- =====================================================================
-- 04_procedures.sql
-- パイプラインの各カードから呼ぶプロシージャ
-- 各カードは「CALL <プロシージャ>」1文だけにして、ロジックはここに集約する。
-- 戻り値(SYSTEM$SET_RETURN_VALUE)はプロシージャ内で設定する。タスク外(ワークシート)から
-- 呼んだ場合は戻り値の設定だけが無視されるので、手動でも順に流して確認できる。
--
-- モデル名 'claude-sonnet-5' は自アカウント・リージョンで AI_COMPLETE に使えるものに置き換える
-- =====================================================================

USE ROLE DECISION_PIPE_ROLE;
USE WAREHOUSE DECISION_PIPE_WH;
USE SCHEMA DECISION_PIPE_DB.SUPPORT;

-- =====================================================================
-- 共通: イベントログ
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
-- T00 (ルート): 今回処理する受付日を決める
--   戻り値: HAS_TICKETS / NO_TICKETS
--   グラフの Config (JSON) の batch_mode を読む('daily'=1日ずつ / 'all'=未処理日をまとめて)
-- =====================================================================
CREATE OR REPLACE PROCEDURE SP_PICK_BATCH()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  bmode VARCHAR DEFAULT 'daily';
  n     NUMBER DEFAULT 0;
  dates VARCHAR;
  rv    VARCHAR;
BEGIN
  BEGIN
    SELECT COALESCE(SYSTEM$GET_TASK_GRAPH_CONFIG('batch_mode')::VARCHAR, 'daily') INTO :bmode;
  EXCEPTION
    WHEN OTHER THEN bmode := 'daily';
  END;

  TRUNCATE TABLE CURRENT_BATCH_DATES;
  TRUNCATE TABLE CURRENT_BATCH;

  IF (bmode = 'all') THEN
    INSERT INTO CURRENT_BATCH_DATES
    SELECT c.RECEIVED_DATE FROM BATCH_CALENDAR c
    WHERE NOT EXISTS (SELECT 1 FROM BATCH_STATE s WHERE s.RECEIVED_DATE = c.RECEIVED_DATE);
  ELSE
    INSERT INTO CURRENT_BATCH_DATES
    SELECT MIN(c.RECEIVED_DATE) FROM BATCH_CALENDAR c
    WHERE NOT EXISTS (SELECT 1 FROM BATCH_STATE s WHERE s.RECEIVED_DATE = c.RECEIVED_DATE)
    HAVING MIN(c.RECEIVED_DATE) IS NOT NULL;
  END IF;

  INSERT INTO CURRENT_BATCH (TICKET_ID, RECEIVED_DATE)
  SELECT t.TICKET_ID, t.RECEIVED_AT::DATE
  FROM SUPPORT_TICKETS t
  JOIN CURRENT_BATCH_DATES d ON d.RECEIVED_DATE = t.RECEIVED_AT::DATE;
  n := SQLROWCOUNT;

  SELECT LISTAGG(TO_VARCHAR(RECEIVED_DATE, 'YYYY-MM-DD'), ',') WITHIN GROUP (ORDER BY RECEIVED_DATE)
    INTO :dates
  FROM CURRENT_BATCH_DATES;

  rv := IFF(n > 0, 'HAS_TICKETS', 'NO_TICKETS');
  BEGIN
    CALL SYSTEM$SET_RETURN_VALUE(:rv);
  EXCEPTION
    WHEN OTHER THEN NULL;
  END;

  RETURN rv || ' mode=' || bmode || ' dates=' || COALESCE(dates, '(なし: 全日処理済み)') || ' tickets=' || n;
END;
$$;

-- =====================================================================
-- T07: 英訳(AI_TRANSLATE)
--   decider-2b は英語で学習されたモデルのため、渡す前に問い合わせを英訳する
--   (1) ヘルプ記事タイトルのうち未翻訳のものを英訳して KB_TRANSLATIONS に蓄積(decider-2b の選択肢に使う)
--   (2) 今回のバッチの問い合わせを英訳して TICKET_TRANSLATIONS に保存
--   失敗した行は TEXT_EN が NULL になり、T10 はその行だけ日本語のまま渡す。
--   翻訳全体が失敗してもタスクは成功扱いにして、後続(T10)を止めない
--   translate_for_decider = 0 のときは何もしない(日本語のまま渡した場合と比べる用)
-- =====================================================================
CREATE OR REPLACE PROCEDURE SP_TRANSLATE()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  use_tr FLOAT;
  n_kb   NUMBER DEFAULT 0;
  n_ok   NUMBER DEFAULT 0;
  n_err  NUMBER DEFAULT 0;
  msg    VARCHAR;
BEGIN
  SELECT COALESCE(CFG('translate_for_decider'), 1) INTO :use_tr;
  IF (use_tr < 1) THEN
    msg := 'skipped (translate_for_decider = 0)';
    CALL SP_LOG_EVENT('T07_TRANSLATE', 'skipped', :msg);
    RETURN msg;
  END IF;

  -- (1) ヘルプ記事タイトル(未翻訳・翻訳失敗のものだけ)
  DELETE FROM KB_TRANSLATIONS WHERE TITLE_EN IS NULL;
  INSERT INTO KB_TRANSLATIONS (KB_ID, TITLE_EN)
  SELECT k.KB_ID, AI_TRANSLATE(k.TITLE, 'ja', 'en')
  FROM KB_ARTICLES k
  WHERE NOT EXISTS (SELECT 1 FROM KB_TRANSLATIONS x WHERE x.KB_ID = k.KB_ID);
  n_kb := SQLROWCOUNT;

  -- (2) 問い合わせ(エラー詳細も残す)
  DELETE FROM TICKET_TRANSLATIONS WHERE TICKET_ID IN (SELECT TICKET_ID FROM CURRENT_BATCH);
  INSERT INTO TICKET_TRANSLATIONS (TICKET_ID, TEXT_EN, ERROR_MESSAGE)
  SELECT TICKET_ID, r:value::STRING, r:error::STRING
  FROM (
    SELECT t.TICKET_ID, AI_TRANSLATE(t.TICKET_TEXT, 'ja', 'en', TRUE) AS r
    FROM SUPPORT_TICKETS t
    JOIN CURRENT_BATCH b ON b.TICKET_ID = t.TICKET_ID
  ) x;

  SELECT COUNT_IF(tr.TEXT_EN IS NOT NULL), COUNT_IF(tr.TEXT_EN IS NULL) INTO :n_ok, :n_err
  FROM TICKET_TRANSLATIONS tr JOIN CURRENT_BATCH b ON b.TICKET_ID = tr.TICKET_ID;

  msg := 'tickets ok=' || n_ok || ' error=' || n_err || ' kb_titles_translated=' || n_kb;
  CALL SP_LOG_EVENT('T07_TRANSLATE', 'translated', :msg);
  RETURN msg;
EXCEPTION
  WHEN OTHER THEN
    msg := 'failed: ' || SQLERRM;
    CALL SP_LOG_EVENT('T07_TRANSLATE', 'failed', :msg);
    RETURN msg;
END;
$$;

-- =====================================================================
-- T10 / T11: 問い合わせの分類
--   METHOD = 'decider' : decider-2b(Model Registry → SPCS サービス DECIDER_2B_SVC)(T10)
--   METHOD = 'llm'     : 汎用LLM + 構造化出力(T11 フォールバック)
--   1回の呼び出しで4つの判定を行う
--     category           : 問い合わせの種類(choice)
--     kb_article         : 回答に使えるヘルプ記事(choice。記事一覧から動的に組み立てる)
--     requires_human     : 担当者の判断・権限・調査が必要か(noul = 真の確率)
--     needs_account_data : 顧客固有のデータ確認が必要か(noul)
--   decider-2b は英語で学習されているため、質問文は英語、問い合わせ本文と記事タイトルは T07 の英訳を渡す
--   (translate_for_decider = 0 または翻訳失敗の行は日本語のまま渡し、INPUT_LANG = 'ja' を記録する)
-- =====================================================================
CREATE OR REPLACE PROCEDURE SP_CLASSIFY(METHOD VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  forced_failure EXCEPTION (-20001, 'シナリオ classify_down による強制失敗(decider-2b 停止の想定)');
  all_unparsed   EXCEPTION (-20002, '分類結果を1件も解析できなかった');
  bad_method     EXCEPTION (-20009, 'METHOD は decider か llm を指定する');
  force_flag FLOAT;
  use_tr     FLOAT;
  n_total    NUMBER DEFAULT 0;
  n_null     NUMBER DEFAULT 0;
BEGIN
  SELECT COALESCE(CFG('force_classify_failure'), 0), COALESCE(CFG('translate_for_decider'), 1)
    INTO :force_flag, :use_tr;
  IF (METHOD = 'decider' AND force_flag >= 1) THEN
    RAISE forced_failure;
  END IF;

  DELETE FROM CLASSIFY_RESULTS WHERE TICKET_ID IN (SELECT TICKET_ID FROM CURRENT_BATCH);

  IF (METHOD = 'decider') THEN
    INSERT INTO CLASSIFY_RESULTS
      (TICKET_ID, CLASSIFY_MODEL, INPUT_LANG, CATEGORY, CATEGORY_CONF, KB_ID, KB_CONF, HUMAN_PROB, ACCOUNT_DATA_PROB, RAW)
    WITH kb AS (
      -- 選択肢: 記事タイトルの英訳(未翻訳・翻訳オフのときは日本語タイトル)
      SELECT OBJECT_INSERT(
               OBJECT_AGG(k.KB_ID, TO_VARIANT(IFF(:use_tr >= 1, COALESCE(x.TITLE_EN, k.TITLE), k.TITLE))),
               'none', 'None of these articles answers the ticket') AS criteria
      FROM KB_ARTICLES k
      LEFT JOIN KB_TRANSLATIONS x ON x.KB_ID = k.KB_ID
    ),
    q AS (
      SELECT TO_JSON({
        'category': {
          'type': 'choice',
          'instructions': 'What is this support ticket about? The category the customer picked on the form may be wrong.',
          'criteria': {
            'how_to':              'How to use or configure a product feature',
            'billing':             'Invoices, payments, seat counts or plan prices',
            'account_access':      'Login, password, two-factor authentication or SSO',
            'api_integration':     'API usage or integrations with other services',
            'outage_bug':          'Outages, errors or something not working',
            'security_privacy':    'Security incidents, personal data, data deletion or legal and contract documents',
            'cancellation_refund': 'Cancellation, downgrade or refunds',
            'other':               'Anything else'
          }
        },
        'kb_article': {
          'type': 'choice',
          'instructions': 'Which help-center article best answers this ticket?',
          'criteria': kb.criteria
        },
        'requires_human': {
          'type': 'noul',
          'instructions': 'Does this ticket need the judgment, authority or investigation of a human support agent? '
                       || 'That includes refunds, discounts, quotes or contract changes; disputes about an invoice amount; '
                       || 'suspected unauthorized access; immediate data deletion or deletion certificates; legal documents; '
                       || 'the only admin being locked out; errors not explained by a known outage; '
                       || 'strong dissatisfaction or a threat to cancel.',
          'criteria': {'true': 'A human agent must handle it', 'false': 'Documented information is enough to answer'}
        },
        'needs_account_data': {
          'type': 'noul',
          'instructions': 'Does answering require data specific to this customer, such as their plan, seat counts, '
                       || 'invoices, API usage, or whether an outage affected them?',
          'criteria': {'true': 'Customer-specific data is needed', 'false': 'General information is enough'}
        }
      }) AS questions_json
      FROM kb
    ),
    src AS (
      SELECT
        t.TICKET_ID,
        IFF(:use_tr >= 1 AND tr.TEXT_EN IS NOT NULL, tr.TEXT_EN, t.TICKET_TEXT) AS STATE_TEXT,
        IFF(:use_tr >= 1 AND tr.TEXT_EN IS NOT NULL, 'en', 'ja')               AS INPUT_LANG
      FROM SUPPORT_TICKETS t
      JOIN CURRENT_BATCH b            ON b.TICKET_ID = t.TICKET_ID
      LEFT JOIN TICKET_TRANSLATIONS tr ON tr.TICKET_ID = t.TICKET_ID
    ),
    d AS (
      SELECT
        s.TICKET_ID, s.INPUT_LANG,
        DECISION_PIPE_DB.SUPPORT.DECIDER_2B_SVC!SYSTEM_ONE(
          TO_JSON(TO_VARIANT(s.STATE_TEXT)),    -- STATE_JSON: 問い合わせ本文(JSON文字列)
          q.questions_json                      -- QUESTIONS_JSON
        ) AS out
      FROM src s
      CROSS JOIN q
    ),
    p AS (
      SELECT TICKET_ID, INPUT_LANG, out, TRY_PARSE_JSON(out:ANSWER_JSON::STRING) AS j FROM d
    )
    SELECT TICKET_ID, 'decider-2b', INPUT_LANG,
           j:answers:category:choice::STRING,
           j:answers:category:confidence::FLOAT,
           j:answers:kb_article:choice::STRING,
           j:answers:kb_article:confidence::FLOAT,
           j:answers:requires_human:noul::FLOAT,
           j:answers:needs_account_data:noul::FLOAT,
           OBJECT_CONSTRUCT_KEEP_NULL(
             'answer',       j,                                   -- 行単位のエラーは {"error": ...}
             'elapsed_ms',   out:ELAPSED_MS,
             'input_tokens', out:INPUT_TOKENS,
             'runtime',      TRY_PARSE_JSON(out:RUNTIME_JSON::STRING))
    FROM p;

  ELSEIF (METHOD = 'llm') THEN
    INSERT INTO CLASSIFY_RESULTS
      (TICKET_ID, CLASSIFY_MODEL, INPUT_LANG, CATEGORY, CATEGORY_CONF, KB_ID, KB_CONF, HUMAN_PROB, ACCOUNT_DATA_PROB, RAW)
    WITH kbl AS (
      SELECT LISTAGG(KB_ID || ': ' || TITLE, '\n') WITHIN GROUP (ORDER BY KB_ID) AS kb_list FROM KB_ARTICLES
    ),
    d AS (
      SELECT
        t.TICKET_ID,
        TRY_PARSE_JSON(TO_VARCHAR(AI_COMPLETE(
          model  => 'claude-sonnet-5',
          prompt => 'SaaSのサポート窓口に届いた問い合わせを分類してください。\n'
                 || 'category: how_to(使い方) / billing(請求・料金) / account_access(ログイン・認証) / '
                 || 'api_integration(API・連携) / outage_bug(障害・不具合) / security_privacy(セキュリティ・データ削除・契約書類) / '
                 || 'cancellation_refund(解約・返金) / other。フォームの区分は誤っていることがある。\n'
                 || 'kb_id: 回答に最も適したヘルプ記事のID。該当がなければ none。\n'
                 || 'requires_human_prob: 担当者の判断・権限・調査が必要な確率(返金・値引き・契約変更、請求金額への異議、'
                 || '不正アクセスの疑い、データの即時削除、法務文書、唯一の管理者のロックアウト、既知の障害以外の不具合、強い不満や解約の示唆)。\n'
                 || 'needs_account_data_prob: 回答に顧客固有のデータ(プラン、シート数、請求書、API利用状況、障害の影響)が必要な確率。\n'
                 || '各 confidence は0〜1。\n\nヘルプ記事一覧:\n' || kbl.kb_list
                 || '\n\n問い合わせ:\n' || t.TICKET_TEXT,
          model_parameters => {'temperature': 0},
          response_format => {
            'type': 'json',
            'schema': {
              'type': 'object',
              'properties': {
                'category': {'type': 'string', 'enum': ['how_to', 'billing', 'account_access', 'api_integration',
                                                        'outage_bug', 'security_privacy', 'cancellation_refund', 'other']},
                'category_confidence': {'type': 'number'},
                'kb_id': {'type': 'string'},
                'kb_confidence': {'type': 'number'},
                'requires_human_prob': {'type': 'number'},
                'needs_account_data_prob': {'type': 'number'}
              },
              'required': ['category', 'category_confidence', 'kb_id', 'kb_confidence',
                           'requires_human_prob', 'needs_account_data_prob']
            }
          }
        ))) AS j0
      FROM SUPPORT_TICKETS t
      JOIN CURRENT_BATCH b ON b.TICKET_ID = t.TICKET_ID
      CROSS JOIN kbl
    ),
    n AS (
      SELECT TICKET_ID, COALESCE(j0:structured_output[0]:raw_message, j0) AS j, j0 FROM d
    )
    SELECT TICKET_ID, 'llm-fallback', 'ja',
           j:category::STRING, j:category_confidence::FLOAT,
           j:kb_id::STRING, j:kb_confidence::FLOAT,
           j:requires_human_prob::FLOAT, j:needs_account_data_prob::FLOAT,
           j0
    FROM n;

  ELSE
    RAISE bad_method;
  END IF;

  SELECT COUNT(*), COUNT_IF(c.CATEGORY IS NULL) INTO :n_total, :n_null
  FROM CLASSIFY_RESULTS c JOIN CURRENT_BATCH b ON b.TICKET_ID = c.TICKET_ID;

  IF (n_total > 0 AND n_null = n_total) THEN
    RAISE all_unparsed;
  END IF;

  RETURN METHOD || ': rows=' || n_total || ' unparsed=' || n_null;
END;
$$;

-- =====================================================================
-- T20: 振り分け
--   human : 担当者が必要(または分類できなかった)
--   auto  : ヘルプ記事が確信度高く特定でき、顧客データが不要 → T40 で定型回答
--   agent : それ以外(ヘルプ記事 + 顧客データの調査が必要) → T30 でエージェント
--   戻り値: ALL_AUTO(agent なし) / AGENT(上限以内) / AGENT_OVERFLOW(上限超過)
-- =====================================================================
CREATE OR REPLACE PROCEDURE SP_ROUTE()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  n_total  NUMBER DEFAULT 0;
  n_auto   NUMBER DEFAULT 0;
  n_agent  NUMBER DEFAULT 0;
  n_human  NUMBER DEFAULT 0;
  max_rows FLOAT;
  rv       VARCHAR;
BEGIN
  DELETE FROM ROUTED_TICKETS WHERE TICKET_ID IN (SELECT TICKET_ID FROM CURRENT_BATCH);

  INSERT INTO ROUTED_TICKETS
    (TICKET_ID, TICKET_TEXT, RECEIVED_AT, CATEGORY, KB_ID, KB_CONF, HUMAN_PROB, ACCOUNT_DATA_PROB, ROUTE, AGENT_PRIORITY)
  WITH r AS (
    SELECT
      t.TICKET_ID, t.TICKET_TEXT, t.RECEIVED_AT,
      c.CATEGORY, c.KB_ID, c.KB_CONF, c.HUMAN_PROB, c.ACCOUNT_DATA_PROB,
      CASE
        WHEN c.CATEGORY IS NULL OR c.HUMAN_PROB IS NULL THEN 'human'    -- 分類できないものは安全側へ
        WHEN c.HUMAN_PROB >= CFG('human_min') THEN 'human'
        WHEN k.KB_ID IS NOT NULL
         AND c.KB_CONF >= CFG('auto_conf_min')
         AND c.ACCOUNT_DATA_PROB < CFG('auto_data_max') THEN 'auto'
        ELSE 'agent'
      END AS ROUTE
    FROM SUPPORT_TICKETS t
    JOIN CURRENT_BATCH b      ON b.TICKET_ID = t.TICKET_ID
    LEFT JOIN CLASSIFY_RESULTS c ON c.TICKET_ID = t.TICKET_ID
    LEFT JOIN KB_ARTICLES k   ON k.KB_ID = c.KB_ID
  )
  SELECT r.*,
         IFF(ROUTE = 'agent',
             ROW_NUMBER() OVER (PARTITION BY ROUTE ORDER BY RECEIVED_AT, TICKET_ID),   -- 受付順
             NULL)
  FROM r;

  SELECT COUNT(*), COUNT_IF(r.ROUTE = 'auto'), COUNT_IF(r.ROUTE = 'agent'), COUNT_IF(r.ROUTE = 'human')
    INTO :n_total, :n_auto, :n_agent, :n_human
  FROM ROUTED_TICKETS r JOIN CURRENT_BATCH b ON b.TICKET_ID = r.TICKET_ID;
  SELECT CFG('agent_max_rows') INTO :max_rows;

  rv := CASE WHEN n_agent = 0 THEN 'ALL_AUTO'
             WHEN n_agent <= max_rows THEN 'AGENT'
             ELSE 'AGENT_OVERFLOW' END;
  BEGIN
    CALL SYSTEM$SET_RETURN_VALUE(:rv);
  EXCEPTION
    WHEN OTHER THEN NULL;
  END;

  RETURN rv || ' total=' || n_total || ' auto=' || n_auto || ' agent=' || n_agent
            || ' human=' || n_human || ' max=' || max_rows;
END;
$$;

-- =====================================================================
-- T30: エージェントによる回答案の作成(優先度 <= agent_max_rows の行だけ)
--   行単位の失敗は記録して続行。失敗率が agent_error_max を超えたらタスクを失敗させる
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
  tid        VARCHAR;
  body       VARCHAR;
  resp       VARCHAR;
  t0         TIMESTAMP_LTZ;
  c1 CURSOR FOR
    SELECT
      r.TICKET_ID,
      TO_JSON(OBJECT_CONSTRUCT(
        'messages', ARRAY_CONSTRUCT(OBJECT_CONSTRUCT(
          'role', 'user',
          'content', ARRAY_CONSTRUCT(OBJECT_CONSTRUCT(
            'type', 'text',
            'text', '次の問い合わせに回答してください。受付日時: '
                    || TO_VARCHAR(r.RECEIVED_AT, 'YYYY-MM-DD HH24:MI') || '\n' || r.TICKET_TEXT
          ))
        ))
      )) AS REQUEST_BODY
    FROM ROUTED_TICKETS r
    JOIN CURRENT_BATCH b ON b.TICKET_ID = r.TICKET_ID
    WHERE r.ROUTE = 'agent'
      AND r.AGENT_PRIORITY <= CFG('agent_max_rows')
    ORDER BY r.AGENT_PRIORITY;
BEGIN
  SELECT COALESCE(CFG('force_agent_failure'), 0), COALESCE(CFG('agent_error_max'), 0.5)
    INTO :force_flag, :err_max;
  IF (force_flag >= 1) THEN
    RAISE forced_failure;
  END IF;

  DELETE FROM AGENT_RESULTS WHERE TICKET_ID IN (SELECT TICKET_ID FROM CURRENT_BATCH);

  FOR rec IN c1 DO
    tid  := rec.TICKET_ID;
    body := rec.REQUEST_BODY;
    t0   := CURRENT_TIMESTAMP();
    BEGIN
      resp := (SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN(
                        'DECISION_PIPE_DB.SUPPORT.SUPPORT_AGENT', :body));

      INSERT INTO AGENT_RESULTS
        (TICKET_ID, STATUS, ANSWER_TEXT, REPLY_TEXT, RESOLUTION, SOURCES, FACTS, RAW_RESPONSE, ELAPSED_MS)
      WITH p AS (SELECT TRY_PARSE_JSON(:resp) AS j),
      t AS (
        SELECT LISTAGG(f.value:text::STRING, '\n') WITHIN GROUP (ORDER BY f.index) AS answer
        FROM p, LATERAL FLATTEN(INPUT => p.j:content) f
        WHERE f.value:type::STRING = 'text'
      ),
      js AS (
        SELECT t.answer, REGEXP_SUBSTR(t.answer, '\\{[^{}]*"resolution"[^{}]*\\}') AS jtxt
        FROM t
      ),
      k AS (
        SELECT answer, TRY_PARSE_JSON(jtxt) AS meta,
               TRIM(IFF(jtxt IS NULL, answer, REPLACE(answer, jtxt, ''))) AS reply
        FROM js
      )
      SELECT :tid, 'ok', k.answer, k.reply,
             LOWER(k.meta:resolution::STRING), k.meta:sources, k.meta:facts::STRING,
             p.j, DATEDIFF('millisecond', :t0, CURRENT_TIMESTAMP())
      FROM p, k;

      n_ok := n_ok + 1;
    EXCEPTION
      WHEN OTHER THEN
        INSERT INTO AGENT_RESULTS (TICKET_ID, STATUS, ERROR_MESSAGE, ELAPSED_MS)
        VALUES (:tid, 'error', :SQLERRM, DATEDIFF('millisecond', :t0, CURRENT_TIMESTAMP()));
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
-- T31 / T35 / T50: 担当者キューへの投入
--   KIND = 'overflow'     : 上限超過でエージェントに回さなかった行(T31)
--   KIND = 'agent_failed' : T30 が失敗したときの退避(T35)
--   KIND = 'final'        : 最終結果で human になった行 + 担当者向け引き継ぎメモの生成(T50)
--   同じチケットは1回だけ投入する(先に入った理由を残し、下書きは後から補う)
-- =====================================================================
CREATE OR REPLACE PROCEDURE SP_ENQUEUE_REVIEW(KIND VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  bad_kind EXCEPTION (-20010, 'KIND は overflow / agent_failed / final のいずれか');
  n       NUMBER DEFAULT 0;
  n_note  NUMBER DEFAULT 0;
  msg     VARCHAR;
BEGIN
  IF (KIND = 'overflow') THEN
    MERGE INTO HUMAN_REVIEW_QUEUE q
    USING (
      SELECT r.TICKET_ID, r.TICKET_TEXT
      FROM ROUTED_TICKETS r JOIN CURRENT_BATCH b ON b.TICKET_ID = r.TICKET_ID
      WHERE r.ROUTE = 'agent' AND r.AGENT_PRIORITY > CFG('agent_max_rows')
    ) s ON q.TICKET_ID = s.TICKET_ID
    WHEN NOT MATCHED THEN INSERT (TICKET_ID, REASON, SOURCE_TASK, TICKET_TEXT)
      VALUES (s.TICKET_ID, 'overflow', 'T31_OVERFLOW_TO_HUMAN', s.TICKET_TEXT);
    n := SQLROWCOUNT;

  ELSEIF (KIND = 'agent_failed') THEN
    MERGE INTO HUMAN_REVIEW_QUEUE q
    USING (
      SELECT r.TICKET_ID, r.TICKET_TEXT
      FROM ROUTED_TICKETS r JOIN CURRENT_BATCH b ON b.TICKET_ID = r.TICKET_ID
      WHERE r.ROUTE = 'agent'
    ) s ON q.TICKET_ID = s.TICKET_ID
    WHEN NOT MATCHED THEN INSERT (TICKET_ID, REASON, SOURCE_TASK, TICKET_TEXT)
      VALUES (s.TICKET_ID, 'agent_failed', 'T35_AGENT_FAILED', s.TICKET_TEXT);
    n := SQLROWCOUNT;

  ELSEIF (KIND = 'final') THEN
    MERGE INTO HUMAN_REVIEW_QUEUE q
    USING (
      SELECT f.TICKET_ID, f.HUMAN_REASON, f.DRAFT_REPLY, t.TICKET_TEXT
      FROM FINAL_RESULTS f
      JOIN CURRENT_BATCH b   ON b.TICKET_ID = f.TICKET_ID
      JOIN SUPPORT_TICKETS t ON t.TICKET_ID = f.TICKET_ID
      WHERE f.FINAL_ROUTE = 'human'
    ) s ON q.TICKET_ID = s.TICKET_ID
    WHEN MATCHED THEN UPDATE SET DRAFT_REPLY = COALESCE(q.DRAFT_REPLY, s.DRAFT_REPLY)
    WHEN NOT MATCHED THEN INSERT (TICKET_ID, REASON, SOURCE_TASK, TICKET_TEXT, DRAFT_REPLY)
      VALUES (s.TICKET_ID, s.HUMAN_REASON, 'T50_HUMAN_QUEUE', s.TICKET_TEXT, s.DRAFT_REPLY);
    n := SQLROWCOUNT;

    -- 担当者向けの引き継ぎメモ(失敗してもキュー投入は残す)
    BEGIN
      UPDATE HUMAN_REVIEW_QUEUE q
         SET HANDOFF_NOTE = AI_COMPLETE(
               'claude-sonnet-5',
               'あなたはSaaSのサポートチームのリーダーです。次の問い合わせを担当者に引き継ぐためのメモを日本語で作成してください。'
               || '「要点」「顧客の要望」「確認・判断が必要な事項」「一次返信の方針」の4項目で、各1〜2行の箇条書きにしてください。'
               || '事実として書けるのは問い合わせと下書きに書かれていることだけです。\n'
               || '\n引き継ぎ理由: ' || q.REASON
               || '\n問い合わせ:\n' || q.TICKET_TEXT
               || '\n下書き(あれば):\n' || COALESCE(q.DRAFT_REPLY, 'なし'))
       WHERE q.HANDOFF_NOTE IS NULL
         AND q.TICKET_ID IN (SELECT TICKET_ID FROM CURRENT_BATCH);
      n_note := SQLROWCOUNT;
    EXCEPTION
      WHEN OTHER THEN
        CALL SP_LOG_EVENT('final', 'handoff_note_failed', :SQLERRM);
    END;

    -- 通知を送る場合は通知統合を作成し、下のコメントを外す
    -- CALL SYSTEM$SEND_SNOWFLAKE_NOTIFICATION(
    --   SNOWFLAKE.NOTIFICATION.TEXT_PLAIN('担当者の対応が必要な問い合わせがあります'),
    --   SNOWFLAKE.NOTIFICATION.INTEGRATION('<email_integration_name>'));
  ELSE
    RAISE bad_kind;
  END IF;

  msg := KIND || ': enqueued=' || n || IFF(KIND = 'final', ' notes=' || n_note, '');
  CALL SP_LOG_EVENT(:KIND, 'enqueue', :msg);
  RETURN msg;
END;
$$;

-- =====================================================================
-- T40: 回答の確定
--   (1) auto の行に、選ばれたヘルプ記事だけを根拠にした定型回答を生成する
--   (2) auto とエージェントの回答案を品質チェックする(decider-2b には英訳して渡す)
--       grounded(根拠スコア 0〜2) / resolves(質問に答えているか) / risky(承認が必要な内容を含むか)
--       decider-2b を試し、失敗・解析不能なら汎用LLMに切り替える
--   (3) 基準を満たすものは送信可、満たさないものは下書き付きで human にする
--   戻り値: REVIEW_NEEDED(human あり) / OK
-- =====================================================================
CREATE OR REPLACE PROCEDURE SP_FINALIZE_ANSWERS()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  use_dec  FLOAT;
  use_tr   FLOAT;
  qmin     FLOAT;
  rmin     FLOAT;
  riskmax  FLOAT;
  maxr     FLOAT;
  qmodel   VARCHAR DEFAULT 'none';
  n_q      NUMBER DEFAULT 0;
  n_scored NUMBER DEFAULT 0;
  n_total  NUMBER DEFAULT 0;
  n_human  NUMBER DEFAULT 0;
  n_send   NUMBER DEFAULT 0;
  rv       VARCHAR;
BEGIN
  SELECT COALESCE(CFG('use_decider_for_quality'), 1), COALESCE(CFG('translate_for_decider'), 1),
         CFG('quality_min'), CFG('resolves_min'), CFG('risk_max'), CFG('agent_max_rows')
    INTO :use_dec, :use_tr, :qmin, :rmin, :riskmax, :maxr;

  -- (1) 定型回答の生成
  DELETE FROM AUTO_ANSWERS WHERE TICKET_ID IN (SELECT TICKET_ID FROM CURRENT_BATCH);
  BEGIN
    INSERT INTO AUTO_ANSWERS (TICKET_ID, KB_ID, REPLY_TEXT, MODEL)
    SELECT
      r.TICKET_ID, r.KB_ID,
      AI_COMPLETE(
        'claude-sonnet-5',
        'あなたはプロジェクト管理SaaS「TaskFlow」のサポート担当です。次のヘルプ記事の内容だけを根拠に、問い合わせへの返信文を日本語の丁寧語で作成してください。'
        || '記事に書かれていないこと(返金、個別の契約内容、日付の約束など)は書かないでください。'
        || '冒頭は「(会社名) ご担当者様」、末尾は「TaskFlowサポート」とし、返信文だけを出力してください。\n'
        || '\nヘルプ記事(' || k.KB_ID || ' ' || k.TITLE || '):\n' || k.BODY
        || '\n\n問い合わせ:\n' || r.TICKET_TEXT),
      'claude-sonnet-5'
    FROM ROUTED_TICKETS r
    JOIN CURRENT_BATCH b ON b.TICKET_ID = r.TICKET_ID
    JOIN KB_ARTICLES k   ON k.KB_ID = r.KB_ID
    WHERE r.ROUTE = 'auto';
  EXCEPTION
    WHEN OTHER THEN
      CALL SP_LOG_EVENT('T40', 'auto_answer_failed', :SQLERRM);   -- auto の行は auto_failed で human へ
  END;

  -- (2) 品質チェックの対象(送信候補)と、照合に使う参照情報
  CREATE OR REPLACE TEMPORARY TABLE TMP_CANDIDATES AS
  WITH src AS (
    SELECT ar.TICKET_ID, f.value::STRING AS KB_ID
    FROM AGENT_RESULTS ar, LATERAL FLATTEN(INPUT => ar.SOURCES) f
    WHERE ar.TICKET_ID IN (SELECT TICKET_ID FROM CURRENT_BATCH)
  ),
  ref AS (
    SELECT s.TICKET_ID, LISTAGG(k.KB_ID || ' ' || k.TITLE || ': ' || k.BODY, '\n') AS KB_REF
    FROM src s JOIN KB_ARTICLES k ON k.KB_ID = s.KB_ID
    GROUP BY s.TICKET_ID
  )
  SELECT r.TICKET_ID, 'auto' AS SRC, r.TICKET_TEXT, a.REPLY_TEXT,
         'ヘルプ記事 ' || k.KB_ID || ' ' || k.TITLE || ': ' || k.BODY AS REFERENCE
  FROM ROUTED_TICKETS r
  JOIN CURRENT_BATCH b ON b.TICKET_ID = r.TICKET_ID
  JOIN AUTO_ANSWERS a  ON a.TICKET_ID = r.TICKET_ID
  JOIN KB_ARTICLES k   ON k.KB_ID = a.KB_ID
  WHERE r.ROUTE = 'auto' AND a.REPLY_TEXT IS NOT NULL
  UNION ALL
  SELECT r.TICKET_ID, 'agent', r.TICKET_TEXT, ar.REPLY_TEXT,
         'ヘルプ記事: ' || COALESCE(ref.KB_REF, '(なし)') || '\n顧客データ: ' || COALESCE(ar.FACTS, '(なし)')
  FROM ROUTED_TICKETS r
  JOIN CURRENT_BATCH b      ON b.TICKET_ID = r.TICKET_ID
  JOIN AGENT_RESULTS ar     ON ar.TICKET_ID = r.TICKET_ID
  LEFT JOIN ref             ON ref.TICKET_ID = r.TICKET_ID
  WHERE r.ROUTE = 'agent' AND ar.STATUS = 'ok' AND ar.RESOLUTION = 'answered'
    AND ar.REPLY_TEXT IS NOT NULL AND ar.REPLY_TEXT <> '';

  CREATE OR REPLACE TEMPORARY TABLE TMP_QUALITY (
    TICKET_ID VARCHAR, SCORE FLOAT, RESOLVES FLOAT, RISK FLOAT, RAW VARIANT);

  IF (use_dec >= 1) THEN
    BEGIN
      -- decider-2b に渡すため、問い合わせ・返信案・参照情報を英訳する(翻訳オフ・失敗時は日本語のまま)
      IF (use_tr >= 1) THEN
        CREATE OR REPLACE TEMPORARY TABLE TMP_CANDIDATES_DEC AS
        SELECT c.TICKET_ID,
               COALESCE(tr.TEXT_EN, c.TICKET_TEXT)                   AS TICKET_IN,
               COALESCE(AI_TRANSLATE(c.REPLY_TEXT, 'ja', 'en'), c.REPLY_TEXT) AS REPLY_IN,
               COALESCE(AI_TRANSLATE(c.REFERENCE,  'ja', 'en'), c.REFERENCE)  AS REFERENCE_IN
        FROM TMP_CANDIDATES c
        LEFT JOIN TICKET_TRANSLATIONS tr ON tr.TICKET_ID = c.TICKET_ID;
      ELSE
        CREATE OR REPLACE TEMPORARY TABLE TMP_CANDIDATES_DEC AS
        SELECT TICKET_ID, TICKET_TEXT AS TICKET_IN, REPLY_TEXT AS REPLY_IN, REFERENCE AS REFERENCE_IN
        FROM TMP_CANDIDATES;
      END IF;

      INSERT INTO TMP_QUALITY
      SELECT TICKET_ID,
             qj:answers:grounded:score::FLOAT,      -- 3段階の期待値(0〜2)
             qj:answers:resolves:noul::FLOAT,
             qj:answers:risky:noul::FLOAT,
             OBJECT_CONSTRUCT_KEEP_NULL('answer', qj, 'elapsed_ms', out:ELAPSED_MS, 'input_tokens', out:INPUT_TOKENS)
      FROM (
        SELECT TICKET_ID, out, TRY_PARSE_JSON(out:ANSWER_JSON::STRING) AS qj
        FROM (
          SELECT
            c.TICKET_ID,
            DECISION_PIPE_DB.SUPPORT.DECIDER_2B_SVC!SYSTEM_ONE(
                   -- STATE_JSON: 問い合わせ・返信案・参照情報をまとめた JSON オブジェクト
                   TO_JSON(OBJECT_CONSTRUCT('ticket', c.TICKET_IN, 'draft_reply', c.REPLY_IN, 'reference', c.REFERENCE_IN)),
                   TO_JSON({
                     'grounded': {
                       'type': 'score',
                       'instructions': 'Is everything in draft_reply supported by reference?',
                       'criteria': ['Not supported, or contradicts the reference', 'Partly supported', 'Fully supported by the reference']
                     },
                     'resolves': {
                       'type': 'noul',
                       'instructions': 'Does draft_reply directly answer the question in ticket?',
                       'criteria': {'true': 'It answers the question', 'false': 'It does not answer the question'}
                     },
                     'risky': {
                       'type': 'noul',
                       'instructions': 'Does draft_reply contain anything that needs a human agent''s approval, such as promising refunds, '
                                    || 'discounts or dates, stating product behavior that is not in reference, '
                                    || 'or revealing information about other customers?',
                       'criteria': {'true': 'It needs approval', 'false': 'It is safe to send'}
                     }
                   })
                 ) AS out
          FROM TMP_CANDIDATES_DEC c
        ) sv
      ) qd;
      SELECT COUNT(*), COUNT(SCORE) INTO :n_q, :n_scored FROM TMP_QUALITY;
      qmodel := IFF(n_q > 0 AND n_scored = 0, 'decider_unparsed', 'decider-2b');
    EXCEPTION
      WHEN OTHER THEN qmodel := 'decider_failed';
    END;
  END IF;

  IF (qmodel <> 'decider-2b') THEN
    DELETE FROM TMP_QUALITY;
    INSERT INTO TMP_QUALITY
    SELECT TICKET_ID,
           COALESCE(j0:structured_output[0]:raw_message:score,         j0:score)::FLOAT,
           COALESCE(j0:structured_output[0]:raw_message:resolves_prob, j0:resolves_prob)::FLOAT,
           COALESCE(j0:structured_output[0]:raw_message:risk_prob,     j0:risk_prob)::FLOAT,
           j0
    FROM (
      SELECT
        c.TICKET_ID,
        TRY_PARSE_JSON(TO_VARCHAR(AI_COMPLETE(
          model  => 'claude-sonnet-5',
          prompt => 'サポートの返信案を評価してください。\n'
                 || 'score: 返信案の内容が参照情報で裏付けられているか(0=裏付けなし・矛盾、1=一部のみ、2=すべて裏付けあり)。\n'
                 || 'resolves_prob: 顧客の質問に直接答えている確率(0〜1)。\n'
                 || 'risk_prob: 返金・値引き・期日の約束、参照情報にない仕様の断定など、担当者の承認が必要な内容を含む確率(0〜1)。\n'
                 || '\n問い合わせ:\n' || c.TICKET_TEXT || '\n\n返信案:\n' || c.REPLY_TEXT || '\n\n参照情報:\n' || c.REFERENCE,
          model_parameters => {'temperature': 0},
          response_format => {
            'type': 'json',
            'schema': {
              'type': 'object',
              'properties': {
                'score': {'type': 'number'},
                'resolves_prob': {'type': 'number'},
                'risk_prob': {'type': 'number'}
              },
              'required': ['score', 'resolves_prob', 'risk_prob']
            }
          }
        ))) AS j0
      FROM TMP_CANDIDATES c
    ) ql;
    qmodel := 'llm' || IFF(qmodel = 'none', '', ' (' || qmodel || ')');
  END IF;

  -- (3) 最終結果
  DELETE FROM FINAL_RESULTS WHERE TICKET_ID IN (SELECT TICKET_ID FROM CURRENT_BATCH);

  INSERT INTO FINAL_RESULTS
    (TICKET_ID, ROUTE, FINAL_ROUTE, FINAL_CATEGORY, FINAL_REPLY, DRAFT_REPLY,
     QUALITY_SCORE, RESOLVES_PROB, RISK_PROB, QUALITY_RAW, HUMAN_REASON, QUALITY_MODEL)
  WITH x AS (
    SELECT
      r.TICKET_ID, r.ROUTE, r.CATEGORY, r.AGENT_PRIORITY,
      c.REPLY_TEXT                                   AS cand_reply,
      COALESCE(a.REPLY_TEXT, NULLIF(ar.REPLY_TEXT, '')) AS draft,
      ar.TICKET_ID                                   AS ar_tid,
      ar.STATUS                                      AS ar_status,
      ar.RESOLUTION                                  AS ar_res,
      q.SCORE, q.RESOLVES, q.RISK, q.RAW,
      COALESCE(c.TICKET_ID IS NOT NULL
               AND q.SCORE >= :qmin AND q.RESOLVES >= :rmin AND q.RISK < :riskmax, FALSE) AS accepted
    FROM ROUTED_TICKETS r
    JOIN CURRENT_BATCH b        ON b.TICKET_ID = r.TICKET_ID
    LEFT JOIN AUTO_ANSWERS a    ON a.TICKET_ID = r.TICKET_ID AND r.ROUTE = 'auto'
    LEFT JOIN AGENT_RESULTS ar  ON ar.TICKET_ID = r.TICKET_ID AND r.ROUTE = 'agent'
    LEFT JOIN TMP_CANDIDATES c  ON c.TICKET_ID = r.TICKET_ID
    LEFT JOIN TMP_QUALITY q     ON q.TICKET_ID = r.TICKET_ID
  )
  SELECT
    TICKET_ID,
    ROUTE,
    IFF(accepted, ROUTE, 'human'),
    CATEGORY,
    IFF(accepted, cand_reply, NULL),
    IFF(accepted, NULL, draft),
    SCORE, RESOLVES, RISK, RAW,
    CASE
      WHEN accepted                                        THEN NULL
      WHEN ROUTE = 'human'                                 THEN 'classified_human'
      WHEN ROUTE = 'auto'  AND draft IS NULL               THEN 'auto_failed'
      WHEN ROUTE = 'agent' AND AGENT_PRIORITY > :maxr      THEN 'overflow'
      WHEN ROUTE = 'agent' AND ar_tid IS NULL              THEN 'agent_not_run'
      WHEN ROUTE = 'agent' AND ar_status = 'error'         THEN 'agent_error'
      WHEN ROUTE = 'agent' AND ar_res = 'needs_human'      THEN 'agent_escalated'
      WHEN ROUTE = 'agent' AND (ar_res IS NULL OR draft IS NULL) THEN 'agent_unparsed'
      WHEN RISK >= :riskmax                                THEN 'risky_reply'
      WHEN RESOLVES < :rmin                                THEN 'not_resolved'
      ELSE 'low_quality'
    END,
    IFF(ROUTE IN ('auto', 'agent'), :qmodel, NULL)
  FROM x;

  SELECT COUNT(*), COUNT_IF(f.FINAL_ROUTE = 'human'), COUNT_IF(f.FINAL_ROUTE IN ('auto', 'agent'))
    INTO :n_total, :n_human, :n_send
  FROM FINAL_RESULTS f JOIN CURRENT_BATCH b ON b.TICKET_ID = f.TICKET_ID;

  rv := IFF(n_human > 0, 'REVIEW_NEEDED', 'OK');
  BEGIN
    CALL SYSTEM$SET_RETURN_VALUE(:rv);
  EXCEPTION
    WHEN OTHER THEN NULL;
  END;

  RETURN rv || ' total=' || n_total || ' send=' || n_send || ' human=' || n_human || ' quality_model=' || qmodel;
END;
$$;

-- =====================================================================
-- T99 (ファイナライザー): 経路とサマリを記録し、完了した受付日を処理済みにする
-- =====================================================================
CREATE OR REPLACE PROCEDURE SP_RUN_SUMMARY()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  gid        VARCHAR DEFAULT NULL;
  dates      VARCHAR;
  n_tickets  NUMBER DEFAULT 0;
  n_final    NUMBER DEFAULT 0;
  run_status VARCHAR;
BEGIN
  BEGIN
    SELECT SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_GRAPH_RUN_GROUP_ID') INTO :gid;
  EXCEPTION
    WHEN OTHER THEN gid := NULL;
  END;

  -- (1) 今回の実行で各タスクがどう終わったか
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
      WHEN OTHER THEN NULL;
    END;
  END IF;

  -- (2) 完了判定
  SELECT LISTAGG(TO_VARCHAR(RECEIVED_DATE, 'YYYY-MM-DD'), ',') WITHIN GROUP (ORDER BY RECEIVED_DATE)
    INTO :dates
  FROM CURRENT_BATCH_DATES;

  SELECT COUNT(b.TICKET_ID), COUNT(f.TICKET_ID) INTO :n_tickets, :n_final
  FROM CURRENT_BATCH b LEFT JOIN FINAL_RESULTS f ON f.TICKET_ID = b.TICKET_ID;

  run_status := CASE WHEN n_tickets = 0 THEN 'no_tickets'
                     WHEN n_final = n_tickets THEN 'complete'
                     ELSE 'incomplete' END;

  -- (3) サマリ(正解ラベルとの突合)
  INSERT INTO RUN_SUMMARY
    (RUN_GROUP_ID, BATCH_DATES, N_TICKETS, CLASSIFY_MODEL, QUALITY_MODEL,
     N_AUTO, N_AGENT, N_HUMAN, N_UNSAFE_AUTOMATION, N_MISSED_AUTOMATION, CATEGORY_ACC, STATUS)
  SELECT
    :gid, :dates, COUNT(b.TICKET_ID),
    MAX(c.CLASSIFY_MODEL), MAX(f.QUALITY_MODEL),
    COUNT_IF(f.FINAL_ROUTE = 'auto'),
    COUNT_IF(f.FINAL_ROUTE = 'agent'),
    COUNT_IF(f.FINAL_ROUTE = 'human'),
    COUNT_IF(f.FINAL_ROUTE IN ('auto', 'agent') AND l.TRUE_RESOLUTION = 'human'),
    COUNT_IF(f.FINAL_ROUTE = 'human' AND l.TRUE_RESOLUTION IN ('kb', 'lookup')),
    AVG(IFF(c.CATEGORY IS NULL, NULL, IFF(c.CATEGORY = l.TRUE_CATEGORY, 1, 0))),
    :run_status
  FROM CURRENT_BATCH b
  LEFT JOIN FINAL_RESULTS f    ON f.TICKET_ID = b.TICKET_ID
  LEFT JOIN CLASSIFY_RESULTS c ON c.TICKET_ID = b.TICKET_ID
  LEFT JOIN TICKET_LABELS l    ON l.TICKET_ID = b.TICKET_ID;

  -- (4) 完了した受付日だけ処理済みにする(incomplete は次回もう一度処理する)
  IF (run_status IN ('complete', 'no_tickets')) THEN
    INSERT INTO BATCH_STATE (RECEIVED_DATE, RUN_GROUP_ID)
    SELECT d.RECEIVED_DATE, :gid FROM CURRENT_BATCH_DATES d
    WHERE NOT EXISTS (SELECT 1 FROM BATCH_STATE s WHERE s.RECEIVED_DATE = d.RECEIVED_DATE);
  END IF;

  RETURN run_status || ' dates=' || COALESCE(dates, '-') || ' tickets=' || n_tickets || ' finalized=' || n_final;
END;
$$;

-- =====================================================================
-- 検証シナリオの切り替え
--   normal        : 通常
--   classify_down : decider-2b での分類(T10)を強制失敗 → T11(汎用LLMでフォールバック)
--   agent_down    : T30 を強制失敗 → T35(退避)
--   overflow      : agent_max_rows = 1 → T31(上限超過の人手送り)
--   drained       : 全日を処理済みにする → 次回は NO_TICKETS で T05 だけ
--   reset         : 結果をすべて消して最初の日からやり直す(設定は normal に戻す)
-- =====================================================================
CREATE OR REPLACE PROCEDURE SP_SET_SCENARIO(NAME VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  bad_name EXCEPTION (-20011, 'normal / classify_down / agent_down / overflow / drained / reset のいずれかを指定する');
  s VARCHAR;
BEGIN
  s := LOWER(NAME);
  IF (s NOT IN ('normal', 'classify_down', 'agent_down', 'overflow', 'drained', 'reset')) THEN
    RAISE bad_name;
  END IF;

  IF (s = 'reset') THEN
    TRUNCATE TABLE BATCH_STATE;
    TRUNCATE TABLE CURRENT_BATCH_DATES;
    TRUNCATE TABLE CURRENT_BATCH;
    TRUNCATE TABLE TICKET_TRANSLATIONS;
    TRUNCATE TABLE KB_TRANSLATIONS;
    TRUNCATE TABLE CLASSIFY_RESULTS;
    TRUNCATE TABLE ROUTED_TICKETS;
    TRUNCATE TABLE AGENT_RESULTS;
    TRUNCATE TABLE AUTO_ANSWERS;
    TRUNCATE TABLE FINAL_RESULTS;
    TRUNCATE TABLE HUMAN_REVIEW_QUEUE;
    TRUNCATE TABLE PIPELINE_EVENTS;
    TRUNCATE TABLE RUN_SUMMARY;
    TRUNCATE TABLE RUN_TASK_STATES;
    s := 'normal';
  END IF;

  IF (s = 'drained') THEN
    INSERT INTO BATCH_STATE (RECEIVED_DATE, RUN_GROUP_ID)
    SELECT c.RECEIVED_DATE, 'scenario:drained' FROM BATCH_CALENDAR c
    WHERE NOT EXISTS (SELECT 1 FROM BATCH_STATE x WHERE x.RECEIVED_DATE = c.RECEIVED_DATE);
  END IF;

  UPDATE PIPELINE_CONFIG
     SET VALUE = CASE KEY
                   WHEN 'force_classify_failure' THEN IFF(:s = 'classify_down', 1, 0)
                   WHEN 'force_agent_failure'    THEN IFF(:s = 'agent_down', 1, 0)
                   WHEN 'agent_max_rows'         THEN IFF(:s = 'overflow', 1, 5)
                 END
   WHERE KEY IN ('force_classify_failure', 'force_agent_failure', 'agent_max_rows');

  CALL SP_LOG_EVENT('SCENARIO', 'set', :s);
  RETURN 'scenario=' || s;
END;
$$;

SELECT * FROM V_BATCH_PREVIEW ORDER BY RECEIVED_DATE;
