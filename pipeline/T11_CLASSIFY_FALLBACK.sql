-- =====================================================================
-- T11_CLASSIFY_FALLBACK  [.sql ファイル]
-- T10(decider-2b)が失敗したときだけ動き、汎用LLMの構造化出力で分類し直す。
-- confidence や確率は LLM の自己申告値なので、decider-2b の確率ほど当てにならない点に注意。
-- モデル名 'claude-sonnet-5' は自アカウントで AI_COMPLETE に使えるものに置き換える。
--
-- Pipeline Builder の設定
--   種類                  : SQL file(このファイル)
--   Predecessors          : T10_CLASSIFY
--   Condition(WHEN)      : SYSTEM$PREDECESSORS_STATE('ALL_FAILED')
-- =====================================================================
USE SCHEMA DECISION_PIPE_DB.SUPPORT;

DELETE FROM CLASSIFY_RESULTS WHERE TICKET_ID IN (SELECT TICKET_ID FROM CURRENT_BATCH);

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

-- 1件も解析できなかった場合は失敗させる(後続の T20 は T10・T11 のどちらも成功していないため動かない)
SELECT TO_NUMBER(IFF(COUNT(*) > 0 AND COUNT(c.CATEGORY) = 0, '汎用LLMでも分類結果を解析できなかった', '0'))
FROM CLASSIFY_RESULTS c
JOIN CURRENT_BATCH b ON b.TICKET_ID = c.TICKET_ID;
