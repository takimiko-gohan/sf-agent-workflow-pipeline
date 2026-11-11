-- =====================================================================
-- 05_decider_model.sql
-- 判定モデル decider-2b(オープンウェイトの jev-class decision model)を
-- Model Registry に登録し、SPCS のサービスとして動かすための準備と確認
--
-- 進め方(README の「decider-2b の登録」も参照)
--   STEP 1. このファイルの [1] を実行する(コンピュートプール・外部アクセス・イメージリポジトリ)
--   STEP 2. 手元の PC で公式サンプルのスクリプトを実行し、モデル登録とサービス作成を行う
--           (Snowflake-Labs/decision-models-in-snowflake-model-registry の log_model.py / create_service.py)
--   STEP 3. このファイルの [2] で、サービスの起動と応答を確認する
--   検証しないときは [3] でサービスとプールを止める(GPU は起動中ずっと課金される)
--
-- 公式サンプルのスクリプトは次の名前を固定で使うため、ここでも同じ名前で作成する
--   GPU プール: DECIDER_BENCH_GPU_POOL / ビルド用プール: DECIDER_BENCH_BUILD_POOL
--   外部アクセス統合: DECIDER_BENCH_BUILD_EAI / イメージリポジトリ: <DB>.<SCHEMA>.DECIDER_BENCH_IMAGES
--   モデル: <DB>.<SCHEMA>.DECIDER_2B(バージョン SERVICE)/ サービス: <DB>.<SCHEMA>.DECIDER_2B_SVC
-- =====================================================================

-- =====================================================================
-- [1] 準備(STEP 1)
-- =====================================================================
USE ROLE ACCOUNTADMIN;

-- 推論用 GPU プール(NVIDIA A10G x1。decider-2b は bf16 で約4GBを使う)
-- GPU_NV_S が使えないリージョンでは作成に失敗する
CREATE COMPUTE POOL IF NOT EXISTS DECIDER_BENCH_GPU_POOL
  MIN_NODES = 1
  MAX_NODES = 1
  INSTANCE_FAMILY = GPU_NV_S
  AUTO_RESUME = TRUE
  AUTO_SUSPEND_SECS = 300
  INITIALLY_SUSPENDED = TRUE
  COMMENT = 'decider-2b 推論サービス(サポート検証)';

-- サービス用イメージのビルドに使う CPU プール
CREATE COMPUTE POOL IF NOT EXISTS DECIDER_BENCH_BUILD_POOL
  MIN_NODES = 1
  MAX_NODES = 1
  INSTANCE_FAMILY = CPU_X64_S
  AUTO_RESUME = TRUE
  AUTO_SUSPEND_SECS = 300
  INITIALLY_SUSPENDED = TRUE
  COMMENT = 'decider-2b イメージビルド';

GRANT USAGE, MONITOR, OPERATE ON COMPUTE POOL DECIDER_BENCH_GPU_POOL   TO ROLE DECISION_PIPE_ROLE;
GRANT USAGE, MONITOR, OPERATE ON COMPUTE POOL DECIDER_BENCH_BUILD_POOL TO ROLE DECISION_PIPE_ROLE;

-- イメージビルド時だけ PyPI と PyTorch のホイール配布元に出られるようにする
-- (動いているサービス自体には外部アクセスを与えない。重みはモデルの成果物として登録される)
CREATE NETWORK RULE IF NOT EXISTS DECISION_PIPE_DB.SUPPORT.DECIDER_BUILD_EGRESS
  MODE = EGRESS
  TYPE = HOST_PORT
  VALUE_LIST = ('pypi.org', 'files.pythonhosted.org', 'download.pytorch.org', 'download-r2.pytorch.org')
  COMMENT = 'decider-2b イメージビルド用(PyPI / PyTorch のみ)';

CREATE EXTERNAL ACCESS INTEGRATION IF NOT EXISTS DECIDER_BENCH_BUILD_EAI
  ALLOWED_NETWORK_RULES = (DECISION_PIPE_DB.SUPPORT.DECIDER_BUILD_EGRESS)
  ENABLED = TRUE
  COMMENT = 'decider-2b イメージビルド専用';

GRANT USAGE ON INTEGRATION DECIDER_BENCH_BUILD_EAI TO ROLE DECISION_PIPE_ROLE;

-- イメージリポジトリ(スキーマ所有者がモデル・サービスも作成する)
USE ROLE DECISION_PIPE_ROLE;
USE WAREHOUSE DECISION_PIPE_WH;
USE SCHEMA DECISION_PIPE_DB.SUPPORT;
CREATE IMAGE REPOSITORY IF NOT EXISTS DECIDER_BENCH_IMAGES;

SHOW COMPUTE POOLS LIKE 'DECIDER_BENCH%';

-- =====================================================================
-- STEP 2 は手元の PC で実行する(README 参照)
--   ・接続の既定ロールを DECISION_PIPE_ROLE にしておく(スクリプトはロールを切り替えない)
--   ・DECIDER_BENCH_DATABASE=DECISION_PIPE_DB / DECIDER_BENCH_SCHEMA=SUPPORT を設定して実行する
--   ・create_service.py は約15分かかる(イメージビルド + GPU ノード起動 + ウォームアップ)
-- =====================================================================

-- =====================================================================
-- [2] サービスの確認(STEP 3)
-- =====================================================================
USE ROLE DECISION_PIPE_ROLE;
USE WAREHOUSE DECISION_PIPE_WH;
USE SCHEMA DECISION_PIPE_DB.SUPPORT;

SHOW MODELS LIKE 'DECIDER_2B';
SHOW VERSIONS IN MODEL DECIDER_2B;
SHOW SERVICES LIKE 'DECIDER_2B_SVC';
SELECT SYSTEM$GET_SERVICE_STATUS('DECISION_PIPE_DB.SUPPORT.DECIDER_2B_SVC');   -- READY になるまで待つ

-- 1件で応答を確認する(STATE_JSON は JSON 文字列、QUESTIONS_JSON は質問の JSON)
-- パイプラインと同じく、日本語の問い合わせを AI_TRANSLATE で英訳してから渡す
WITH src AS (
  SELECT AI_TRANSLATE('ログインしようとしたところ、パスワードを忘れてしまいました。再設定の方法を教えてください。', 'ja', 'en') AS text_en
),
r AS (
  SELECT text_en, DECIDER_2B_SVC!SYSTEM_ONE(
           TO_JSON(TO_VARIANT(text_en)),
           TO_JSON({
             'category': {
               'type': 'choice',
               'instructions': 'What is this support ticket about?',
               'criteria': {
                 'account_access': 'Login, password, two-factor authentication or SSO',
                 'billing':        'Invoices, payments, seat counts or plan prices',
                 'other':          'Anything else'
               }
             },
             'requires_human': {
               'type': 'noul',
               'instructions': 'Does this ticket need a human support agent?',
               'criteria': {'true': 'A human agent must handle it', 'false': 'Documented information is enough'}
             }
           })
         ) AS out
  FROM src
)
SELECT
  text_en,
  TRY_PARSE_JSON(out:ANSWER_JSON::STRING)                         AS answer,         -- answers.category.choice / probabilities など
  out:ELAPSED_MS::FLOAT                                           AS elapsed_ms,
  out:INPUT_TOKENS::INT                                           AS input_tokens,
  TRY_PARSE_JSON(out:RUNTIME_JSON::STRING)                        AS runtime         -- GPU・カーネルの実行経路
FROM r;

-- =====================================================================
-- [3] 停止・再開(検証しない間は止める)
-- =====================================================================
-- ALTER SERVICE DECISION_PIPE_DB.SUPPORT.DECIDER_2B_SVC SUSPEND;
-- ALTER COMPUTE POOL DECIDER_BENCH_GPU_POOL SUSPEND;            -- サービス停止後、ノードを解放する
--
-- 再開するとき(READY まで数分かかる)
-- ALTER COMPUTE POOL DECIDER_BENCH_GPU_POOL RESUME;
-- ALTER SERVICE DECISION_PIPE_DB.SUPPORT.DECIDER_2B_SVC RESUME;
