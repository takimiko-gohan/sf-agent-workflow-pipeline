-- =====================================================================
-- 01_synthetic_data.sql
-- 架空のプロジェクト管理SaaS「TaskFlow」のサポート検証用合成データ
--   ・顧客40社、プラン上限、請求書(5〜9月)、API利用(10月日次)、障害履歴4件
--   ・ヘルプ記事18本(回答の根拠)
--   ・問い合わせフォームのチケット(2026-10-02〜10-31、約220件)と正解ラベル
-- 乱数は HASH ベースなので、何度流しても同じデータになる
-- 会社名・製品名・URLはすべて架空
-- =====================================================================

USE ROLE DECISION_PIPE_ROLE;
USE WAREHOUSE DECISION_PIPE_WH;
USE SCHEMA DECISION_PIPE_DB.SUPPORT;

-- 決定的な疑似乱数(0〜1)
CREATE OR REPLACE FUNCTION RAND01(k VARCHAR)
RETURNS FLOAT
AS 'ABS(HASH(k)) % 1000000 / 1000000.0';

-- =====================================================================
-- 1. プランと上限
-- =====================================================================
CREATE OR REPLACE TABLE PLAN_LIMITS (
  PLAN                      VARCHAR,
  MAX_SEATS                 NUMBER,
  API_CALLS_PER_DAY         NUMBER,
  STORAGE_GB                NUMBER,
  MAX_FILE_MB               NUMBER,
  PRICE_PER_SEAT_JPY        NUMBER,     -- 税別・月額
  SSO_AVAILABLE             BOOLEAN,
  INVOICE_PAYMENT_AVAILABLE BOOLEAN
) COMMENT = 'プランごとの上限と料金' AS
SELECT * FROM VALUES
  ('Free',       5,       1000,     5,   10,    0, FALSE, FALSE),
  ('Standard',   50,     10000,   100,  100, 1200, FALSE, FALSE),
  ('Business',   300,   100000,  1000,  500, 2400, TRUE,  TRUE),
  ('Enterprise', 5000, 1000000, 10000, 2000, 3600, TRUE,  TRUE);

-- =====================================================================
-- 2. 顧客アカウント
-- =====================================================================
CREATE OR REPLACE TABLE DIM_ACCOUNT COMMENT = '顧客アカウント' AS
WITH g AS (
  SELECT 1000 + ROW_NUMBER() OVER (ORDER BY SEQ4()) AS ACCOUNT_ID
  FROM TABLE(GENERATOR(ROWCOUNT => 40))
),
a AS (
  SELECT
    ACCOUNT_ID,
    '株式会社'
      || ARRAY_CONSTRUCT('あおば','ひかり','みなと','さくら','つばさ','いろは','こだま','ほくと','かえで','すばる')
           [MOD(ACCOUNT_ID, 10)::INT]::STRING
      || ARRAY_CONSTRUCT('商事','システムズ','物流','製作所')
           [MOD(FLOOR(ACCOUNT_ID / 10), 4)::INT]::STRING                      AS COMPANY_NAME,
    CASE WHEN RAND01('plan' || ACCOUNT_ID) < 0.2 THEN 'Free'
         WHEN RAND01('plan' || ACCOUNT_ID) < 0.6 THEN 'Standard'
         WHEN RAND01('plan' || ACCOUNT_ID) < 0.9 THEN 'Business'
         ELSE 'Enterprise' END                                                 AS PLAN,
    RAND01('seat' || ACCOUNT_ID)                                               AS r_seat,
    RAND01('used' || ACCOUNT_ID)                                               AS r_used
  FROM g
),
b AS (
  SELECT a.*,
    CASE PLAN WHEN 'Free'     THEN 5
              WHEN 'Standard' THEN 10  + FLOOR(r_seat * 40)
              WHEN 'Business' THEN 60  + FLOOR(r_seat * 240)
              ELSE                 400 + FLOOR(r_seat * 1600) END              AS SEATS_CONTRACTED
  FROM a
)
SELECT
  ACCOUNT_ID,
  COMPANY_NAME,
  PLAN,
  SEATS_CONTRACTED::NUMBER                                                     AS SEATS_CONTRACTED,
  FLOOR(SEATS_CONTRACTED * (0.6 + 0.4 * r_used))::NUMBER                       AS SEATS_USED,
  IFF(PLAN <> 'Free' AND RAND01('st' || ACCOUNT_ID) < 0.12, 'past_due', 'active') AS STATUS,
  IFF(RAND01('rg' || ACCOUNT_ID) < 0.7, 'JP-East', 'JP-West')                  AS REGION,
  CASE WHEN PLAN = 'Free' THEN 'なし'
       WHEN PLAN IN ('Business', 'Enterprise') AND RAND01('pm' || ACCOUNT_ID) < 0.5 THEN '請求書払い'
       ELSE 'クレジットカード' END                                              AS PAYMENT_METHOD,
  IFF(PLAN = 'Free', NULL,
      DATEADD(month, FLOOR(RAND01('rn' || ACCOUNT_ID) * 12), '2026-11-01'::DATE)) AS CONTRACT_RENEWAL_DATE
FROM b;

-- =====================================================================
-- 3. 請求書(有料プランのみ、2026年5〜9月分)
--    9月分は支払期限 10/31。カード払いは支払済み、請求書払いは未払い(期限内)
--    past_due の顧客は 8月分が支払期限超過
-- =====================================================================
CREATE OR REPLACE TABLE FACT_INVOICE COMMENT = '請求書' AS
WITH m AS (
  SELECT DATEADD(month, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, '2026-05-01'::DATE) AS BILLING_MONTH
  FROM TABLE(GENERATOR(ROWCOUNT => 5))
)
SELECT
  'INV-' || a.ACCOUNT_ID || '-' || TO_VARCHAR(m.BILLING_MONTH, 'YYYYMM')         AS INVOICE_ID,
  a.ACCOUNT_ID,
  m.BILLING_MONTH,
  ROUND(a.SEATS_CONTRACTED * p.PRICE_PER_SEAT_JPY * 1.1)::NUMBER(12, 0)         AS AMOUNT_JPY,   -- 税込
  LAST_DAY(DATEADD(month, 1, m.BILLING_MONTH))                                  AS DUE_DATE,
  CASE
    WHEN m.BILLING_MONTH <= '2026-07-01' THEN '支払済み'
    WHEN m.BILLING_MONTH =  '2026-08-01' THEN IFF(a.STATUS = 'past_due', '支払期限超過', '支払済み')
    ELSE IFF(a.PAYMENT_METHOD = 'クレジットカード' AND a.STATUS <> 'past_due', '支払済み', '未払い')
  END                                                                           AS STATUS
FROM DIM_ACCOUNT a
JOIN PLAN_LIMITS p ON p.PLAN = a.PLAN
CROSS JOIN m
WHERE a.PLAN <> 'Free';

-- =====================================================================
-- 4. API利用(2026年10月の日次)。一部の顧客は上限超過(429)が発生
-- =====================================================================
CREATE OR REPLACE TABLE FACT_API_USAGE_DAILY COMMENT = 'API利用の日次集計' AS
WITH d AS (
  SELECT DATEADD(day, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, '2026-10-01'::DATE) AS USAGE_DATE
  FROM TABLE(GENERATOR(ROWCOUNT => 31))
),
u AS (
  SELECT
    a.ACCOUNT_ID, d.USAGE_DATE, p.API_CALLS_PER_DAY,
    CASE WHEN RAND01('heavy' || a.ACCOUNT_ID) < 0.3
          AND RAND01('spike' || a.ACCOUNT_ID || d.USAGE_DATE) < 0.35
         THEN 1.1 + 0.4 * RAND01('sr' || a.ACCOUNT_ID || d.USAGE_DATE)
         ELSE 0.2 + 0.6 * RAND01('nr' || a.ACCOUNT_ID || d.USAGE_DATE) END AS ratio
  FROM DIM_ACCOUNT a
  JOIN PLAN_LIMITS p ON p.PLAN = a.PLAN
  CROSS JOIN d
)
SELECT
  ACCOUNT_ID,
  USAGE_DATE,
  ROUND(API_CALLS_PER_DAY * ratio)::NUMBER                                     AS API_REQUESTS,
  GREATEST(ROUND(API_CALLS_PER_DAY * ratio) - API_CALLS_PER_DAY, 0)::NUMBER    AS RATE_LIMITED_REQUESTS
FROM u;

-- =====================================================================
-- 5. 障害履歴(ステータスページの記録)
-- =====================================================================
CREATE OR REPLACE TABLE INCIDENTS (
  INCIDENT_ID     VARCHAR,
  STARTED_AT      TIMESTAMP_NTZ,
  RESOLVED_AT     TIMESTAMP_NTZ,
  COMPONENT       VARCHAR,
  AFFECTED_REGION VARCHAR,
  SEVERITY        VARCHAR,
  STATUS          VARCHAR,
  SUMMARY         VARCHAR
) COMMENT = '障害履歴' AS
SELECT * FROM VALUES
  ('INC-20261007', '2026-10-07 09:10'::TIMESTAMP_NTZ, '2026-10-07 10:40'::TIMESTAMP_NTZ,
   'ファイル添付', 'ALL',     '重大',   '解決済み', 'ファイルのアップロードとダウンロードが失敗する障害が発生しました。'),
  ('INC-20261015', '2026-10-15 14:00'::TIMESTAMP_NTZ, '2026-10-15 16:30'::TIMESTAMP_NTZ,
   '通知メール',   'ALL',     '軽微',   '解決済み', '通知メールの配信が最大2時間遅延しました。'),
  ('INC-20261023', '2026-10-23 08:30'::TIMESTAMP_NTZ, '2026-10-23 09:15'::TIMESTAMP_NTZ,
   'ログイン',     'JP-West', '重大',   '解決済み', 'JP-Westリージョンでログインできない障害が発生しました。'),
  ('INC-20261029', '2026-10-29 13:00'::TIMESTAMP_NTZ, '2026-10-30 11:00'::TIMESTAMP_NTZ,
   'API',          'ALL',     '中程度', '解決済み', 'APIの応答遅延とタイムアウトが断続的に発生しました。');

-- =====================================================================
-- 6. ヘルプ記事(既存の情報 = 自動回答の根拠)
-- =====================================================================
CREATE OR REPLACE TABLE KB_ARTICLES (
  KB_ID    VARCHAR,
  CATEGORY VARCHAR,
  TITLE    VARCHAR,
  BODY     VARCHAR
) COMMENT = 'ヘルプセンターの記事' AS
SELECT * FROM VALUES
  ('KB001', 'account_access', 'パスワードを再設定する',
   'ログイン画面の「パスワードをお忘れの方」から登録メールアドレスを入力すると、再設定用のリンクが届きます。リンクの有効期限は24時間です。メールが届かない場合は迷惑メールフォルダを確認してください。管理者がSSOを必須にしているワークスペースでは、パスワードではなく自社のIDプロバイダーでログインします。'),
  ('KB002', 'account_access', '2段階認証(2FA)の設定と端末紛失時の対応',
   '個人設定の「セキュリティ」から認証アプリを登録して有効化します。管理者は「ワークスペース設定 > セキュリティ」で全メンバーに2段階認証を必須にできます。メンバーが端末を紛失した場合は、管理者がメンバー管理画面から2段階認証をリセットできます。管理者が1名のみで本人がログインできない場合は、本人確認が必要なためサポート担当者が個別に対応します。'),
  ('KB003', 'how_to', 'メンバーの招待と権限ロール',
   '「メンバー管理 > 招待」からメールアドレスを入力して招待します。ロールは「管理者」「メンバー」「閲覧者」の3種類で、閲覧者はタスクの閲覧とコメントのみ可能です。閲覧者を含め、招待したメンバーはすべてシート数に含まれます。'),
  ('KB004', 'billing', 'シート数の追加・削除と料金への反映',
   '管理者は「プランと請求 > シート数」から変更できます。追加分は当月の残り日数で日割り計算され、翌月の請求書に加算されます。削除は翌月の請求から反映され、当月分の返金はありません。プランのシート数上限を超える場合は上位プランへの変更が必要です。'),
  ('KB005', 'billing', 'プランごとの上限と料金',
   'Free: 最大5シート、API 1日1,000回、ストレージ5GB、1ファイル10MB。Standard: 最大50シート、API 1日10,000回、ストレージ100GB、1ファイル100MB、1シート月額1,200円(税別)。Business: 最大300シート、API 1日100,000回、ストレージ1TB、1ファイル500MB、1シート月額2,400円(税別)、SSOと請求書払いに対応。Enterprise: 最大5,000シート、API 1日1,000,000回、ストレージ10TB、1ファイル2GB、1シート月額3,600円(税別)、SSOと請求書払いに対応。'),
  ('KB006', 'billing', '請求書のダウンロードと宛名の変更',
   '管理者は「プランと請求 > 請求履歴」から過去の請求書をPDFでダウンロードできます。宛名と住所は「請求先情報」で変更でき、変更後に発行される請求書から反映されます。発行済みの請求書の宛名変更は、担当者による再発行が必要です。'),
  ('KB007', 'billing', '支払い方法の変更',
   'クレジットカードの変更は「プランと請求 > 支払い方法」から行えます。請求書払い(銀行振込)はBusinessプラン以上で利用でき、申込フォームから申請すると翌月の請求から切り替わります。Free・Standardプランでは請求書払いは利用できません。'),
  ('KB008', 'api_integration', 'APIのレート制限と429エラー',
   'APIの呼び出し回数にはプランごとに1日あたりの上限があります(上限はKB005を参照)。上限を超えると、その日の残りの時間はHTTP 429が返ります。回数は毎日0時(日本時間)にリセットされます。上限を超える場合は、リトライの間隔を空ける、一括取得のAPIを使う、上位プランに変更する、のいずれかを検討してください。'),
  ('KB009', 'api_integration', 'APIキーの発行と無効化',
   '管理者は「ワークスペース設定 > API」から新しいキーを発行できます。不要になったキーは同じ画面で無効化でき、無効化は即時に反映されます。キーは発行時に一度だけ表示されるため、安全な場所に保管してください。'),
  ('KB010', 'account_access', 'SSO(SAML)の設定',
   'BusinessプランとEnterpriseプランで利用できます。「ワークスペース設定 > セキュリティ > SSO」で、IDプロバイダー(Microsoft Entra ID、Okta、Google Workspaceなど)のメタデータを登録します。SSOを必須にすると、パスワードでのログインは無効になります。Free・Standardプランでは利用できません。'),
  ('KB011', 'how_to', 'データのエクスポート',
   'プロジェクトの「…」メニューから「エクスポート」を選ぶと、CSVまたはJSON形式で出力できます。ワークスペース全体のエクスポートは管理者のみ実行でき、完了するとダウンロードリンクがメールで届きます。添付ファイルはエクスポートに含まれません。'),
  ('KB012', 'how_to', '削除したタスクの復元',
   '削除したタスクはゴミ箱に30日間保管され、ゴミ箱から復元できます。30日を過ぎると完全に削除され、復元できません。プロジェクトごと削除した場合も、30日以内であれば管理者がゴミ箱から復元できます。'),
  ('KB013', 'how_to', '通知メールが届かない場合の確認事項',
   '個人設定の「通知」で該当する通知がオンになっているかを確認してください。次に、迷惑メールフォルダと、社内のメールフィルタで notify@taskflow.example が許可されているかを確認してください。障害による遅延の可能性がある場合は、ステータスページ(KB016)を確認してください。'),
  ('KB014', 'api_integration', 'Slack連携の設定',
   '「ワークスペース設定 > 連携 > Slack」から「接続」を押し、Slackの認可画面で許可します。その後、プロジェクトごとに通知先のチャンネルと、通知するイベント(作成・完了・コメントなど)を選べます。Slack側で管理者の承認が必要な場合があります。'),
  ('KB015', 'how_to', 'ファイル添付の上限',
   '1ファイルあたりの上限はプランによって異なります(Free 10MB、Standard 100MB、Business 500MB、Enterprise 2GB)。上限を超えるファイルはアップロード時にエラーになります。ワークスペース全体のストレージ上限もプランごとに決まっています(KB005を参照)。'),
  ('KB016', 'outage_bug', '障害情報の確認方法',
   '障害やメンテナンスの情報はステータスページ(status.taskflow.example)で公開しています。障害ごとに発生時刻、影響範囲、復旧時刻を記録しています。ステータスページに掲載されていない不具合は、再現手順を添えてサポートに報告してください。'),
  ('KB017', 'cancellation_refund', '解約とダウングレード',
   '管理者は「プランと請求 > プラン変更」から下位プランへの変更や解約ができます。変更と解約は当月末に反映され、月の途中での解約による返金はありません。ダウングレード後に上限を超えているデータは閲覧のみ可能になります。解約後90日でデータは削除されます。'),
  ('KB018', 'security_privacy', 'データの保持と削除',
   '解約後のデータは90日間保持され、その後自動的に削除されます。即時の完全削除や削除証明書の発行を希望する場合は、本人確認と管理者の承認が必要なため、サポート担当者が個別に対応します。');

-- 判定モデル decider-2b は英語で学習されているため、選択肢に使う英語タイトルも持たせる
ALTER TABLE KB_ARTICLES ADD COLUMN TITLE_EN VARCHAR;
UPDATE KB_ARTICLES k
   SET TITLE_EN = v.TITLE_EN
  FROM (SELECT * FROM VALUES
    ('KB001', 'Reset your password'),
    ('KB002', 'Set up two-factor authentication (2FA) and what to do when a device is lost'),
    ('KB003', 'Invite members and assign roles'),
    ('KB004', 'Add or remove seats and how billing changes'),
    ('KB005', 'Limits and prices of each plan'),
    ('KB006', 'Download invoices and change the billing name'),
    ('KB007', 'Change the payment method (card or invoice payment)'),
    ('KB008', 'API rate limits and HTTP 429 errors'),
    ('KB009', 'Issue and revoke API keys'),
    ('KB010', 'Set up SSO (SAML)'),
    ('KB011', 'Export data'),
    ('KB012', 'Restore deleted tasks'),
    ('KB013', 'Notification emails are not arriving'),
    ('KB014', 'Set up the Slack integration'),
    ('KB015', 'File attachment size limits'),
    ('KB016', 'Check service status and outages'),
    ('KB017', 'Cancel or downgrade the plan'),
    ('KB018', 'Data retention and deletion')
  ) v (KB_ID, TITLE_EN)
 WHERE k.KB_ID = v.KB_ID;

-- =====================================================================
-- 7. 問い合わせのテンプレート
--    TRUE_RESOLUTION: kb     = ヘルプ記事だけで回答できる
--                     lookup = ヘルプ記事 + 顧客データの確認で回答できる
--                     human  = 担当者の判断・権限・調査が必要
--    FACT_TYPE: lookup の回答に含まれるべき値(評価用)
--    プレースホルダ: {n} 人数 / {inc_date} 障害日 / {inc_component} 障害箇所
-- =====================================================================
CREATE OR REPLACE TABLE TICKET_TEMPLATES (
  TEMPLATE_ID     VARCHAR,
  TRUE_CATEGORY   VARCHAR,
  TRUE_RESOLUTION VARCHAR,
  TRUE_KB_ID      VARCHAR,
  FACT_TYPE       VARCHAR,
  WEIGHT          NUMBER,
  SUBJECT         VARCHAR,
  BODY            VARCHAR
) COMMENT = '問い合わせ生成用テンプレート(評価用。パイプラインからは参照しない)' AS
SELECT * FROM VALUES
  -- ---- kb: ヘルプ記事だけで回答できる ----
  ('T01', 'account_access', 'kb', 'KB001', NULL, 4, 'パスワードを忘れました',
   'ログインしようとしたところ、パスワードを忘れてしまいました。再設定の方法を教えてください。'),
  ('T02', 'how_to', 'kb', 'KB003', NULL, 4, 'メンバーを招待したい',
   '新しく入社したメンバーをワークスペースに招待したいです。招待の手順と、閲覧だけできる権限にする方法を教えてください。'),
  ('T03', 'how_to', 'kb', 'KB012', NULL, 4, '削除したタスクを元に戻したい',
   '誤ってタスクを削除してしまいました。元に戻すことはできますか。'),
  ('T04', 'how_to', 'kb', 'KB011', NULL, 4, 'データをCSVで出力したい',
   'プロジェクトのデータを社内の集計用にCSVで出力したいのですが、どこから操作できますか。'),
  ('T05', 'api_integration', 'kb', 'KB014', NULL, 4, 'Slack連携の設定方法',
   'タスクの更新をSlackのチャンネルに通知したいです。設定方法を教えてください。'),
  ('T06', 'api_integration', 'kb', 'KB009', NULL, 4, 'APIキーを作り直したい',
   'APIキーを管理していた担当者が退職したため、新しいキーを発行して古いキーを無効にしたいです。'),
  ('T07', 'billing', 'kb', 'KB006', NULL, 4, '請求書の宛名を変えたい',
   '請求書の宛名を部署名入りに変更したいです。また、過去の請求書はどこからダウンロードできますか。'),
  ('T08', 'how_to', 'kb', 'KB013', NULL, 4, '通知メールが届かない',
   'タスクの期限通知メールが届かなくなりました。何を確認すればよいでしょうか。'),
  ('T09', 'how_to', 'kb', 'KB015', NULL, 4, 'ファイルが添付できない',
   '大きめの動画ファイルを添付しようとするとエラーになります。添付できるファイルの大きさに上限はありますか。'),
  ('T10', 'account_access', 'kb', 'KB002', NULL, 4, '2段階認証を全員に必須にしたい',
   'セキュリティ強化のため、メンバー全員に2段階認証を必須にしたいです。設定方法を教えてください。'),
  ('T11', 'cancellation_refund', 'kb', 'KB017', NULL, 4, 'ダウングレードの手順',
   '来月から下位のプランに変更したいと考えています。手続きの方法と、変更後にデータがどうなるか教えてください。'),
  -- ---- lookup: 顧客データの確認が必要 ----
  ('L01', 'billing', 'lookup', 'KB006', 'invoice_amount', 4, '9月分の請求について',
   '9月分の請求金額と支払い状況を確認したいです。経理から問い合わせがありました。'),
  ('L02', 'billing', 'lookup', 'KB004', 'seats_contracted', 4, '契約シート数の確認',
   '現在の契約シート数と、実際に使っているシート数を教えてください。来月メンバーが{n}名増える予定です。'),
  ('L03', 'api_integration', 'lookup', 'KB008', 'api_limit', 4, 'APIで429エラーが返ってくる',
   '10月に入ってからAPIを呼び出すと、ときどき429エラーが返ってきます。当社の契約での上限はいくつですか。'),
  ('L04', 'outage_bug', 'lookup', 'KB016', 'incident_end', 4, '{inc_date}の障害について',
   '{inc_date}に{inc_component}が使えない時間帯がありました。障害が発生していたのでしょうか。いつ復旧したのかも教えてください。'),
  ('L05', 'how_to', 'lookup', 'KB005', 'storage', 4, 'ストレージの上限を知りたい',
   '添付ファイルが増えてきました。当社のプランだと、ストレージの上限はどれくらいですか。'),
  ('L06', 'billing', 'lookup', 'KB007', 'plan_name', 4, '請求書払いに変更したい',
   '支払い方法をクレジットカードから請求書払いに変更できますか。'),
  ('L07', 'account_access', 'lookup', 'KB010', 'plan_name', 4, 'SSOを使いたい',
   'Microsoft Entra IDを使ったシングルサインオンを設定したいです。当社の契約で利用できますか。'),
  -- ---- human: 担当者の対応が必要 ----
  ('H01', 'cancellation_refund', 'human', 'KB017', NULL, 3, '返金をお願いしたい',
   '先月はほとんど使っていなかったので、先月分の料金を返金していただけないでしょうか。'),
  ('H02', 'billing', 'human', 'KB004', NULL, 3, '請求金額が違うのでは',
   '9月分の請求金額が契約内容と合っていないように思います。8月にシート数を減らしたはずですが反映されていません。確認と訂正をお願いします。'),
  ('H03', 'security_privacy', 'human', NULL, NULL, 3, '不正ログインの疑い',
   '身に覚えのない海外からのログイン通知が届きました。不正アクセスされていないか調査してほしいです。'),
  ('H04', 'security_privacy', 'human', 'KB018', NULL, 3, 'データの完全削除と証明書',
   '契約終了に伴い、当社のデータを直ちに完全削除し、削除証明書を発行してください。'),
  ('H05', 'outage_bug', 'human', 'KB016', NULL, 3, 'ガントチャートでエラーが出る',
   'ガントチャート画面を開くと「予期しないエラーが発生しました」と表示されます。他のメンバーでも再現し、今朝から続いています。'),
  ('H06', 'cancellation_refund', 'human', 'KB017', NULL, 3, '解約を考えています',
   '最近動作が遅く業務に支障が出ています。改善されないなら今月で解約するつもりです。担当の方から連絡をください。'),
  ('H07', 'billing', 'human', 'KB005', NULL, 3, '見積もりと値引きの相談',
   '来年度から500名規模に利用を拡大したいです。ボリュームディスカウントを含めた見積もりをお願いできますか。'),
  ('H08', 'security_privacy', 'human', NULL, NULL, 3, 'データ処理契約の締結',
   '法務部からデータ処理契約書(DPA)の締結を求められています。御社の雛形とサブプロセッサーの一覧をいただけますか。'),
  ('H09', 'account_access', 'human', 'KB002', NULL, 3, '管理者がログインできない',
   '唯一の管理者がスマートフォンを紛失し、2段階認証が通らずログインできなくなりました。ほかに管理者はいません。');

-- =====================================================================
-- 8. 問い合わせチケット(2026-10-02〜10-31)
--    平日 6〜13件、土曜 0〜2件、日曜 0〜1件
--    フォームの区分は 80% が正しく、20% は顧客が誤って選んだ区分
-- =====================================================================
CREATE OR REPLACE TEMPORARY TABLE TMP_TICKETS AS
WITH days AS (
  SELECT DATEADD(day, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, '2026-10-02'::DATE) AS D
  FROM TABLE(GENERATOR(ROWCOUNT => 30))
),
slots AS (
  SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS SLOT FROM TABLE(GENERATOR(ROWCOUNT => 16))
),
vol AS (
  SELECT D,
    CASE WHEN DAYOFWEEKISO(D) = 7 THEN IFF(RAND01('v' || D) < 0.5, 0, 1)
         WHEN DAYOFWEEKISO(D) = 6 THEN FLOOR(RAND01('v' || D) * 3)
         ELSE 6 + FLOOR(RAND01('v' || D) * 8) END AS N
  FROM days
),
base AS (
  SELECT
    v.D, s.SLOT,
    DATEADD(minute, 540 + FLOOR(RAND01('m' || v.D || s.SLOT) * 600), v.D::TIMESTAMP_NTZ) AS RECEIVED_AT,
    1001 + FLOOR(RAND01('acct' || v.D || s.SLOT) * 40)                                AS ACCOUNT_ID,
    RAND01('tpl'  || v.D || s.SLOT) AS r_tpl,
    RAND01('tone' || v.D || s.SLOT) AS r_tone,
    RAND01('form' || v.D || s.SLOT) AS r_form,
    RAND01('n'    || v.D || s.SLOT) AS r_n
  FROM vol v JOIN slots s ON s.SLOT <= v.N
),
tw AS (
  SELECT TEMPLATE_ID, WEIGHT,
         SUM(WEIGHT) OVER (ORDER BY TEMPLATE_ID ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cum_hi,
         SUM(WEIGHT) OVER () AS total
  FROM TICKET_TEMPLATES
),
picked AS (
  SELECT b.*,
    -- 最初の障害より前の日は、障害テンプレートを通知メールの質問に差し替える
    IFF(tw.TEMPLATE_ID = 'L04' AND b.RECEIVED_AT < '2026-10-07 11:00'::TIMESTAMP_NTZ, 'T08', tw.TEMPLATE_ID) AS TEMPLATE_ID
  FROM base b
  JOIN tw ON b.r_tpl * tw.total >= tw.cum_hi - tw.WEIGHT AND b.r_tpl * tw.total < tw.cum_hi
),
with_inc AS (
  SELECT p.*, a.COMPANY_NAME, a.PLAN, a.SEATS_CONTRACTED, a.REGION,
         i.INCIDENT_ID, i.STARTED_AT AS INC_STARTED_AT, i.RESOLVED_AT AS INC_RESOLVED_AT, i.COMPONENT AS INC_COMPONENT
  FROM picked p
  JOIN DIM_ACCOUNT a ON a.ACCOUNT_ID = p.ACCOUNT_ID
  LEFT JOIN INCIDENTS i
    ON p.TEMPLATE_ID = 'L04'
   AND i.STARTED_AT < p.RECEIVED_AT
   AND i.AFFECTED_REGION IN ('ALL', a.REGION)
  QUALIFY ROW_NUMBER() OVER (PARTITION BY p.D, p.SLOT ORDER BY i.STARTED_AT DESC NULLS LAST) = 1
)
SELECT
  w.*,
  t.TRUE_CATEGORY, t.TRUE_RESOLUTION, t.TRUE_KB_ID, t.FACT_TYPE,
  -- 該当する障害がない地域の顧客は、通知メールの質問(kb)に差し替える
  IFF(w.TEMPLATE_ID = 'L04' AND w.INCIDENT_ID IS NULL, TRUE, FALSE) AS NO_INCIDENT,
  t.SUBJECT AS SUBJECT_TPL,
  t.BODY    AS BODY_TPL
FROM with_inc w
JOIN TICKET_TEMPLATES t ON t.TEMPLATE_ID = w.TEMPLATE_ID;

-- 障害テンプレートで該当障害がない行を T08 に差し替え
UPDATE TMP_TICKETS x
   SET TEMPLATE_ID = 'T08', TRUE_CATEGORY = t.TRUE_CATEGORY, TRUE_RESOLUTION = t.TRUE_RESOLUTION,
       TRUE_KB_ID = t.TRUE_KB_ID, FACT_TYPE = t.FACT_TYPE, SUBJECT_TPL = t.SUBJECT, BODY_TPL = t.BODY
  FROM TICKET_TEMPLATES t
 WHERE t.TEMPLATE_ID = 'T08' AND x.NO_INCIDENT;

CREATE OR REPLACE TABLE SUPPORT_TICKETS COMMENT = '問い合わせフォームから届いたチケット' AS
WITH f AS (
  SELECT
    x.*,
    'TKT-' || LPAD(ROW_NUMBER() OVER (ORDER BY x.RECEIVED_AT, x.SLOT)::VARCHAR, 5, '0') AS TICKET_ID,
    REPLACE(REPLACE(REPLACE(x.SUBJECT_TPL,
      '{n}', (2 + FLOOR(x.r_n * 8))::VARCHAR),
      '{inc_date}', COALESCE(MONTH(x.INC_STARTED_AT) || '月' || DAY(x.INC_STARTED_AT) || '日', '')),
      '{inc_component}', COALESCE(x.INC_COMPONENT, ''))                                AS SUBJECT,
    REPLACE(REPLACE(REPLACE(x.BODY_TPL,
      '{n}', (2 + FLOOR(x.r_n * 8))::VARCHAR),
      '{inc_date}', COALESCE(MONTH(x.INC_STARTED_AT) || '月' || DAY(x.INC_STARTED_AT) || '日', '')),
      '{inc_component}', COALESCE(x.INC_COMPONENT, ''))                                AS BODY_CORE,
    CASE x.TRUE_CATEGORY
      WHEN 'how_to'              THEN '使い方'
      WHEN 'billing'             THEN '請求・契約'
      WHEN 'cancellation_refund' THEN '請求・契約'
      WHEN 'account_access'      THEN 'アカウント・ログイン'
      WHEN 'api_integration'     THEN 'API・連携'
      WHEN 'outage_bug'          THEN '不具合・障害'
      ELSE 'その他' END                                                                AS FORM_CORRECT
  FROM TMP_TICKETS x
)
SELECT
  TICKET_ID,
  RECEIVED_AT,
  ACCOUNT_ID,
  COMPANY_NAME,
  IFF(r_form < 0.8, FORM_CORRECT,
      ARRAY_CONSTRUCT('使い方','請求・契約','アカウント・ログイン','API・連携','不具合・障害','その他')
        [MOD(FLOOR(r_form * 1000), 6)::INT]::STRING)                                    AS FORM_CATEGORY,
  SUBJECT,
  CASE WHEN r_tone < 0.5 THEN '' WHEN r_tone < 0.8 THEN 'お世話になっております。' ELSE '急ぎで確認したいです。' END
    || BODY_CORE || '\n' || COMPANY_NAME || ' 担当者'                                   AS BODY,
  TEMPLATE_ID, TRUE_CATEGORY, TRUE_RESOLUTION, TRUE_KB_ID, FACT_TYPE,
  PLAN, SEATS_CONTRACTED, INC_RESOLVED_AT
FROM f;

-- 正解ラベル(評価専用。検索サービス・セマンティックビュー・エージェントからは参照させない)
CREATE OR REPLACE TABLE TICKET_LABELS COMMENT = '評価用の正解ラベル' AS
SELECT
  t.TICKET_ID, t.TEMPLATE_ID, t.TRUE_CATEGORY, t.TRUE_RESOLUTION, t.TRUE_KB_ID,
  CASE t.FACT_TYPE
    WHEN 'invoice_amount'   THEN TO_VARCHAR(inv.AMOUNT_JPY)
    WHEN 'seats_contracted' THEN TO_VARCHAR(t.SEATS_CONTRACTED)
    WHEN 'api_limit'        THEN TO_VARCHAR(p.API_CALLS_PER_DAY)
    WHEN 'storage'          THEN IFF(p.STORAGE_GB >= 1000, (p.STORAGE_GB / 1000)::INT || 'TB', p.STORAGE_GB || 'GB')
    WHEN 'plan_name'        THEN t.PLAN
    WHEN 'incident_end'     THEN TO_VARCHAR(t.INC_RESOLVED_AT, 'HH24:MI')
  END AS EXPECTED_FACT
FROM SUPPORT_TICKETS t
JOIN PLAN_LIMITS p ON p.PLAN = t.PLAN
LEFT JOIN FACT_INVOICE inv
  ON inv.ACCOUNT_ID = t.ACCOUNT_ID AND inv.BILLING_MONTH = '2026-09-01'::DATE;

-- パイプラインに渡す列だけを残す(正解やテンプレート由来の列を落とす)
ALTER TABLE SUPPORT_TICKETS DROP COLUMN TEMPLATE_ID, TRUE_CATEGORY, TRUE_RESOLUTION, TRUE_KB_ID,
                                        FACT_TYPE, PLAN, SEATS_CONTRACTED, INC_RESOLVED_AT;

-- 分類・エージェントに渡すテキスト(フォームの項目をまとめたもの)
ALTER TABLE SUPPORT_TICKETS ADD COLUMN TICKET_TEXT VARCHAR;
UPDATE SUPPORT_TICKETS
   SET TICKET_TEXT = 'チケットID: ' || TICKET_ID
                  || '\nアカウントID: ' || ACCOUNT_ID
                  || '\n会社名: ' || COMPANY_NAME
                  || '\n問い合わせ区分(フォームで顧客が選択): ' || FORM_CATEGORY
                  || '\n件名: ' || SUBJECT
                  || '\n本文: ' || BODY;

-- =====================================================================
-- 確認
-- =====================================================================
SELECT COUNT(*) AS tickets FROM SUPPORT_TICKETS;
SELECT TRUE_RESOLUTION, TRUE_CATEGORY, COUNT(*) AS n
FROM TICKET_LABELS GROUP BY 1, 2 ORDER BY 1, 2;
SELECT RECEIVED_AT::DATE AS d, COUNT(*) AS n FROM SUPPORT_TICKETS GROUP BY 1 ORDER BY 1;
SELECT TICKET_TEXT FROM SUPPORT_TICKETS ORDER BY TICKET_ID LIMIT 3;
