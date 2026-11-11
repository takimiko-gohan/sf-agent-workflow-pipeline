-- =====================================================================
-- 02_search_semantic_view_agent.sql
-- 回答エージェントが使う2つのツールと、エージェント本体を作成する
--   ・kb_search    : ヘルプ記事の Cortex Search サービス
--   ・account_data : 顧客データ(契約・請求・API利用・障害履歴)のセマンティックビュー
-- 正解ラベル(TICKET_LABELS)とテンプレート(TICKET_TEMPLATES)はどちらにも含めない
-- =====================================================================

USE ROLE DECISION_PIPE_ROLE;
USE WAREHOUSE DECISION_PIPE_WH;
USE SCHEMA DECISION_PIPE_DB.SUPPORT;

-- =====================================================================
-- 1. ヘルプ記事の検索サービス
--    日本語の記事なので多言語対応の埋め込みモデルを指定する。
--    自リージョンで使えない場合は EMBEDDING_MODEL の行を外す(既定モデルは英語向け)
-- =====================================================================
CREATE OR REPLACE CORTEX SEARCH SERVICE KB_SEARCH
  ON SEARCH_TEXT
  ATTRIBUTES CATEGORY
  WAREHOUSE = DECISION_PIPE_WH
  TARGET_LAG = '1 day'
  EMBEDDING_MODEL = 'snowflake-arctic-embed-l-v2.0'
AS
  SELECT KB_ID, TITLE, CATEGORY, BODY, TITLE || '\n' || BODY AS SEARCH_TEXT
  FROM DECISION_PIPE_DB.SUPPORT.KB_ARTICLES;

-- 動作確認(インデックス作成直後は少し待つ)
SELECT PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
  'DECISION_PIPE_DB.SUPPORT.KB_SEARCH',
  '{"query": "パスワードを忘れた", "columns": ["KB_ID", "TITLE"], "limit": 3}'
)):results AS results;

-- =====================================================================
-- 2. 顧客データのセマンティックビュー
-- =====================================================================
CREATE OR REPLACE SEMANTIC VIEW SUPPORT_ACCOUNT_SV
  TABLES (
    accounts AS DECISION_PIPE_DB.SUPPORT.DIM_ACCOUNT
      PRIMARY KEY (ACCOUNT_ID)
      WITH SYNONYMS ('顧客', 'アカウント', '契約者')
      COMMENT = '顧客アカウント(契約プラン、シート数、支払い方法、更新日)',
    plans AS DECISION_PIPE_DB.SUPPORT.PLAN_LIMITS
      PRIMARY KEY (PLAN)
      WITH SYNONYMS ('プラン', '料金プラン', 'プラン上限')
      COMMENT = 'プランごとの上限(シート数、API回数、ストレージ、ファイルサイズ)と料金',
    invoices AS DECISION_PIPE_DB.SUPPORT.FACT_INVOICE
      PRIMARY KEY (INVOICE_ID)
      WITH SYNONYMS ('請求書', '請求', '支払い')
      COMMENT = '月ごとの請求書(金額は税込)',
    api_usage AS DECISION_PIPE_DB.SUPPORT.FACT_API_USAGE_DAILY
      PRIMARY KEY (ACCOUNT_ID, USAGE_DATE)
      WITH SYNONYMS ('API利用', 'API呼び出し', 'レート制限')
      COMMENT = '顧客ごとのAPIリクエスト数と、上限超過で拒否されたリクエスト数(日次)',
    incidents AS DECISION_PIPE_DB.SUPPORT.INCIDENTS
      PRIMARY KEY (INCIDENT_ID)
      WITH SYNONYMS ('障害', '障害履歴', 'ステータスページ')
      COMMENT = 'サービス障害の履歴(発生・復旧時刻、影響範囲)'
  )
  RELATIONSHIPS (
    accounts_to_plans    AS accounts (PLAN) REFERENCES plans,
    invoices_to_accounts AS invoices (ACCOUNT_ID) REFERENCES accounts,
    usage_to_accounts    AS api_usage (ACCOUNT_ID) REFERENCES accounts
  )
  FACTS (
    accounts.seats_contracted AS SEATS_CONTRACTED COMMENT = '契約シート数',
    accounts.seats_used AS SEATS_USED COMMENT = '利用中のシート数',
    plans.max_seats AS MAX_SEATS COMMENT = 'プランのシート数上限',
    plans.api_calls_per_day AS API_CALLS_PER_DAY COMMENT = 'プランのAPI呼び出し上限(1日あたり)',
    plans.storage_gb AS STORAGE_GB COMMENT = 'プランのストレージ上限(GB)',
    plans.max_file_mb AS MAX_FILE_MB COMMENT = 'プランの1ファイルあたりの上限(MB)',
    plans.price_per_seat_jpy AS PRICE_PER_SEAT_JPY COMMENT = '1シートの月額(円、税別)',
    invoices.amount_jpy AS AMOUNT_JPY COMMENT = '請求金額(円、税込)',
    api_usage.api_requests AS API_REQUESTS COMMENT = 'APIリクエスト数',
    api_usage.rate_limited_requests AS RATE_LIMITED_REQUESTS COMMENT = '上限超過で429になったリクエスト数'
  )
  DIMENSIONS (
    accounts.account_id AS ACCOUNT_ID WITH SYNONYMS ('アカウントID', '顧客ID') COMMENT = 'アカウントID',
    accounts.company_name AS COMPANY_NAME WITH SYNONYMS ('会社名') COMMENT = '会社名',
    accounts.plan_name AS PLAN WITH SYNONYMS ('契約プラン') COMMENT = '契約中のプラン(フリー / スタンダード / ビジネス / エンタープライズ)',
    accounts.account_status AS STATUS COMMENT = 'アカウントの状態(有効 / 支払遅延)',
    accounts.region AS REGION WITH SYNONYMS ('リージョン', '地域') COMMENT = '利用リージョン(東日本 / 西日本)',
    accounts.payment_method AS PAYMENT_METHOD WITH SYNONYMS ('支払い方法') COMMENT = '支払い方法',
    accounts.renewal_date AS CONTRACT_RENEWAL_DATE WITH SYNONYMS ('更新日', '契約更新日') COMMENT = '契約更新日',
    plans.plan_key AS PLAN COMMENT = 'プラン名',
    plans.sso_available AS SSO_AVAILABLE COMMENT = 'SSOを利用できるか',
    plans.invoice_payment_available AS INVOICE_PAYMENT_AVAILABLE COMMENT = '請求書払いを利用できるか',
    invoices.invoice_id AS INVOICE_ID COMMENT = '請求書番号',
    invoices.billing_month AS BILLING_MONTH WITH SYNONYMS ('請求月', '何月分') COMMENT = '請求対象月(月初日)',
    invoices.due_date AS DUE_DATE WITH SYNONYMS ('支払期限') COMMENT = '支払期限',
    invoices.invoice_status AS STATUS WITH SYNONYMS ('支払い状況') COMMENT = '支払済み / 未払い / 支払期限超過',
    api_usage.usage_date AS USAGE_DATE COMMENT = 'API利用日',
    incidents.incident_id AS INCIDENT_ID COMMENT = '障害ID',
    incidents.started_at AS STARTED_AT WITH SYNONYMS ('発生時刻') COMMENT = '障害の発生時刻(日本時間)',
    incidents.resolved_at AS RESOLVED_AT WITH SYNONYMS ('復旧時刻') COMMENT = '障害の復旧時刻(日本時間)',
    incidents.component AS COMPONENT WITH SYNONYMS ('機能') COMMENT = '障害が起きた機能',
    incidents.affected_region AS AFFECTED_REGION COMMENT = '影響リージョン(東日本 / 西日本 / 全リージョン)',
    incidents.severity AS SEVERITY COMMENT = '重大度',
    incidents.incident_status AS STATUS COMMENT = '障害の状態',
    incidents.summary AS SUMMARY COMMENT = '障害の概要'
  )
  METRICS (
    api_usage.total_api_requests AS SUM(api_usage.api_requests) COMMENT = 'APIリクエスト数の合計',
    api_usage.total_rate_limited AS SUM(api_usage.rate_limited_requests) COMMENT = '429になったリクエスト数の合計',
    api_usage.max_daily_requests AS MAX(api_usage.api_requests) COMMENT = '1日あたりの最大リクエスト数',
    invoices.total_amount AS SUM(invoices.amount_jpy) COMMENT = '請求金額の合計'
  )
  COMMENT = 'TaskFlow の顧客データ(サポート回答用)'
  AI_SQL_GENERATION '顧客を特定するときは account_id で絞り込む。請求月は billing_month(月初日)で比較する。障害の影響は affected_region が顧客のリージョンか全リージョンのものを対象にする。';

-- 動作確認
SELECT * FROM SEMANTIC_VIEW(
  SUPPORT_ACCOUNT_SV
  DIMENSIONS accounts.account_id, accounts.plan_name, plans.api_calls_per_day
) ORDER BY 1 LIMIT 5;

-- =====================================================================
-- 3. 回答エージェント
--    最終回答の末尾に JSON を1行出させ、後続で resolution(回答済み / 要担当者)を取り出す
-- =====================================================================
CREATE OR REPLACE AGENT SUPPORT_AGENT
  COMMENT = 'TaskFlow の問い合わせに回答案を作るエージェント'
  PROFILE = '{"display_name": "TaskFlow サポート回答"}'
  FROM SPECIFICATION
  $$
  models:
    orchestration: auto

  orchestration:
    budget:
      seconds: 120
      tokens: 32000

  instructions:
    orchestration: >
      あなたはプロジェクト管理SaaS「TaskFlow」のサポート担当です。
      問い合わせに答えるために、まず kb_search で関連するヘルプ記事を探してください。
      契約プラン、シート数、請求書、API利用状況、障害の影響など、その顧客に固有の情報が
      必要な場合は、問い合わせに書かれたアカウントIDで絞り込んで account_data に照会してください。
      障害の有無は、問い合わせの日時と顧客のリージョンを障害履歴と照らし合わせて判断してください。
      次の場合は回答せず、担当者に引き継いでください:
      返金・値引き・見積もり・契約条件の変更、請求金額への異議、不正アクセスなどセキュリティ事故の疑い、
      データの即時削除や証明書の発行、法務文書の依頼、管理者が1名でログインできない場合、
      障害履歴にない不具合の調査、強い不満や解約の示唆があり担当者からの連絡を求めている場合。
      ヘルプ記事と照会結果で確認できないことは書かないでください。
    response: >
      顧客向けの返信文を日本語の丁寧語で書いてください。
      冒頭は「(会社名) ご担当者様」、末尾は「TaskFlowサポート」としてください。
      数値や日時は照会結果の値をそのまま使ってください。
      担当者に引き継ぐ場合は、問い合わせを受け付けたことと、担当者から連絡することだけを書いてください。
      回答の最後の行には、次の形式の JSON だけを1行で出力してください。
      {"resolution": "answered または needs_human", "sources": ["参照したヘルプ記事のKB_ID"], "facts": "回答に使った顧客データの要約"}

  tools:
    - tool_spec:
        type: "cortex_search"
        name: "kb_search"
        description: "TaskFlow のヘルプ記事(使い方、料金と請求、API、セキュリティ、解約などの公式手順と方針)を検索する"
    - tool_spec:
        type: "cortex_analyst_text_to_sql"
        name: "account_data"
        description: "顧客アカウントの契約プラン・シート数・請求書・API利用状況、プランごとの上限、障害履歴を照会する"

  tool_resources:
    kb_search:
      search_service: "DECISION_PIPE_DB.SUPPORT.KB_SEARCH"
      max_results: 3
      id_column: "KB_ID"
      title_column: "TITLE"
    account_data:
      semantic_view: "DECISION_PIPE_DB.SUPPORT.SUPPORT_ACCOUNT_SV"
      execution_environment:
        type: "warehouse"
        warehouse: "DECISION_PIPE_WH"
  $$;

-- 単発の動作確認(顧客データの確認が必要な問い合わせ)
SELECT TRY_PARSE_JSON(
  SNOWFLAKE.CORTEX.DATA_AGENT_RUN(
    'DECISION_PIPE_DB.SUPPORT.SUPPORT_AGENT',
    $${
      "messages": [
        {"role": "user",
         "content": [{"type": "text",
                      "text": "次の問い合わせに回答してください。\nアカウントID: 1003\n件名: APIで429エラーが返ってくる\n本文: 10月に入ってからAPIを呼び出すと、ときどき429エラーが返ってきます。当社の契約での上限はいくつですか。"}]}
      ]
    }$$
  )
):content AS content;
