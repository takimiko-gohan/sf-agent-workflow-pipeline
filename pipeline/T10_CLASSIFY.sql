-- =====================================================================
-- T10_CLASSIFY  [.sql ファイル]
-- decider-2b(SPCS サービス DECIDER_2B_SVC)で問い合わせを分類する。1回の呼び出しで4項目:
--   category(choice)/ kb_article(choice、選択肢は記事タイトルの英訳)/
--   requires_human(noul)/ needs_account_data(noul)
-- 入力は T07 の英訳(英訳がない行は日本語のまま。INPUT_LANG に記録)。
-- サービス未起動・シナリオの強制失敗・全件解析不能ならタスクが失敗し、T11 が汎用LLMで分類し直す。
--
-- Pipeline Builder の設定
--   種類                  : SQL file(このファイル)
--   Predecessors          : T00_PICK_BATCH, T07_TRANSLATE
--   Condition(WHEN)      : SYSTEM$GET_PREDECESSOR_RETURN_VALUE('T00_PICK_BATCH') = 'HAS_TICKETS'
--                           AND SYSTEM$PREDECESSORS_STATE('ALL_DONE')
--                           (T07 が失敗しても日本語のまま分類を続ける)
-- =====================================================================
USE SCHEMA DECISION_PIPE_DB.SUPPORT;

-- シナリオ classify_down: 強制失敗(TO_NUMBER の変換エラーでタスクを止め、メッセージを残す)
SELECT TO_NUMBER(IFF(CFG('force_classify_failure') >= 1,
                     '強制失敗: シナリオ classify_down(decider-2b 停止の想定)', '0'));

DELETE FROM CLASSIFY_RESULTS WHERE TICKET_ID IN (SELECT TICKET_ID FROM CURRENT_BATCH);

INSERT INTO CLASSIFY_RESULTS
  (TICKET_ID, CLASSIFY_MODEL, INPUT_LANG, CATEGORY, CATEGORY_CONF, KB_ID, KB_CONF, HUMAN_PROB, ACCOUNT_DATA_PROB, RAW)
WITH kb AS (
  -- 選択肢: 記事タイトルの英訳(未翻訳・翻訳オフのときは日本語タイトル)
  SELECT OBJECT_INSERT(
           OBJECT_AGG(k.KB_ID, TO_VARIANT(IFF(CFG('translate_for_decider') >= 1, COALESCE(x.TITLE_EN, k.TITLE), k.TITLE))),
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
    IFF(CFG('translate_for_decider') >= 1 AND tr.TEXT_EN IS NOT NULL, tr.TEXT_EN, t.TICKET_TEXT) AS STATE_TEXT,
    IFF(CFG('translate_for_decider') >= 1 AND tr.TEXT_EN IS NOT NULL, 'en', 'ja')               AS INPUT_LANG
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

-- 1件も解析できなかった場合は失敗させて T11 に回す
SELECT TO_NUMBER(IFF(COUNT(*) > 0 AND COUNT(c.CATEGORY) = 0,
                     '分類結果を1件も解析できなかった(decider-2b の応答を CLASSIFY_RESULTS.RAW で確認)', '0'))
FROM CLASSIFY_RESULTS c
JOIN CURRENT_BATCH b ON b.TICKET_ID = c.TICKET_ID;
