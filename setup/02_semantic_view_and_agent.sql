-- =====================================================================
-- 02_semantic_view_and_agent.sql
-- 原因調査エージェント用のセマンティックビューと Cortex Agent を作成する
-- ※ 正解ラベル(TRUE_CAUSE, WEATHER_EVENT, ALERT_LABELS)はビューに含めない
-- =====================================================================

USE ROLE DECISION_PIPE_ROLE;
USE WAREHOUSE DECISION_PIPE_WH;
USE SCHEMA DECISION_PIPE_DB.DEMO;

-- ---------- セマンティックビュー ----------
-- 結合経路: sales → weather(店舗×日) → stores、sales → items
-- sales → stores を直接張ると経路が2本になり曖昧になるため、weather 経由の1本にしている
CREATE OR REPLACE SEMANTIC VIEW DEMAND_ALERT_SV
  TABLES (
    stores AS DECISION_PIPE_DB.DEMO.DIM_STORE
      PRIMARY KEY (STORE_ID)
      WITH SYNONYMS ('店舗', '店')
      COMMENT = '店舗マスタ',
    items AS DECISION_PIPE_DB.DEMO.DIM_ITEM
      PRIMARY KEY (ITEM_ID)
      WITH SYNONYMS ('品目', '商品', 'SKU')
      COMMENT = '品目マスタ',
    weather AS DECISION_PIPE_DB.DEMO.FACT_WEATHER_DAILY
      PRIMARY KEY (STORE_ID, SALES_DATE)
      WITH SYNONYMS ('天候', '天気', '気象')
      COMMENT = '店舗ごとの日次の最高気温と降水量',
    sales AS DECISION_PIPE_DB.DEMO.FACT_SALES_DAILY
      PRIMARY KEY (STORE_ID, ITEM_ID, SALES_DATE)
      WITH SYNONYMS ('販売実績', '需要予測', '売上数量')
      COMMENT = '店舗×品目×日の需要予測と販売実績、販促・欠品フラグ'
  )
  RELATIONSHIPS (
    sales_to_weather AS sales (STORE_ID, SALES_DATE) REFERENCES weather,
    weather_to_stores AS weather (STORE_ID) REFERENCES stores,
    sales_to_items AS sales (ITEM_ID) REFERENCES items
  )
  FACTS (
    sales.forecast_units AS FORECAST_UNITS COMMENT = '需要予測数量(個)',
    sales.actual_units AS ACTUAL_UNITS COMMENT = '販売実績数量(個)',
    weather.max_temp_c AS MAX_TEMP_C COMMENT = '最高気温(℃)',
    weather.rain_mm AS RAIN_MM COMMENT = '降水量(mm)'
  )
  DIMENSIONS (
    stores.store_id AS STORE_ID COMMENT = '店舗ID',
    stores.store_name AS STORE_NAME WITH SYNONYMS ('店舗名') COMMENT = '店舗名',
    stores.region AS REGION WITH SYNONYMS ('地域', 'エリア') COMMENT = '地域',
    items.item_id AS ITEM_ID COMMENT = '品目ID',
    items.item_name AS ITEM_NAME WITH SYNONYMS ('商品名') COMMENT = '品目名',
    items.category AS CATEGORY WITH SYNONYMS ('カテゴリ') COMMENT = '品目カテゴリ',
    sales.sales_date AS SALES_DATE WITH SYNONYMS ('日付', '販売日') COMMENT = '販売日',
    sales.promo_flag AS PROMO_FLAG WITH SYNONYMS ('販促', 'キャンペーン') COMMENT = 'その日に販促を実施したか',
    sales.stockout_flag AS STOCKOUT_FLAG WITH SYNONYMS ('欠品', '品切れ') COMMENT = 'その日に欠品が発生したか',
    weather.weather_date AS SALES_DATE COMMENT = '天候の日付'
  )
  METRICS (
    sales.total_actual_units AS SUM(sales.actual_units) COMMENT = '販売実績の合計',
    sales.total_forecast_units AS SUM(sales.forecast_units) COMMENT = '需要予測の合計',
    sales.forecast_error_rate AS
      (SUM(sales.actual_units) - SUM(sales.forecast_units)) / NULLIF(SUM(sales.forecast_units), 0)
      WITH SYNONYMS ('予測誤差率')
      COMMENT = '(実績 - 予測) / 予測',
    weather.avg_max_temp AS AVG(weather.max_temp_c) COMMENT = '平均最高気温',
    weather.total_rain_mm AS SUM(weather.rain_mm) COMMENT = '降水量合計'
  )
  COMMENT = '需要予測アラートの原因調査用セマンティックビュー'
  AI_SQL_GENERATION '日付の比較には sales_date を使う。前後の傾向を見るときは対象日の前後7日間を対象にする。';

-- 動作確認
SELECT * FROM SEMANTIC_VIEW(
  DEMAND_ALERT_SV
  METRICS sales.total_actual_units, sales.total_forecast_units
  DIMENSIONS items.category
) ORDER BY 1;

-- ---------- Cortex Agent ----------
-- 最終回答の末尾に JSON を1行出させ、後続ステップで cause を機械的に取り出す
CREATE OR REPLACE AGENT DEMAND_ALERT_AGENT
  COMMENT = '需要予測アラートの原因を調査するエージェント'
  PROFILE = '{"display_name": "需要予測アラート調査"}'
  FROM SPECIFICATION
  $$
  models:
    orchestration: auto

  orchestration:
    budget:
      seconds: 90
      tokens: 32000

  instructions:
    orchestration: >
      あなたは小売の需要予測アナリストです。与えられたアラートについて、
      demand_analyst ツールで該当店舗・品目・日付の販促フラグ、欠品フラグ、
      最高気温、降水量を確認してください。必要に応じて同じ店舗の他品目や
      前後7日間と比較し、原因を promo(販促)、weather(天候)、stock(欠品)、
      unknown(特定不能)のいずれかに判定してください。
      データで確認できない推測は根拠に含めないでください。
    response: >
      日本語で簡潔に回答してください。根拠は確認した数値を挙げて2〜3文で述べてください。
      回答の最後の行には、次の形式の JSON だけを1行で出力してください。
      {"cause": "promo|weather|stock|unknown", "evidence": "根拠の要約"}

  tools:
    - tool_spec:
        type: "cortex_analyst_text_to_sql"
        name: "demand_analyst"
        description: "店舗×品目×日の需要予測・販売実績・販促/欠品フラグと、店舗別の日次天候(最高気温・降水量)を照会する"

  tool_resources:
    demand_analyst:
      semantic_view: "DECISION_PIPE_DB.DEMO.DEMAND_ALERT_SV"
      execution_environment:
        type: "warehouse"
        warehouse: "DECISION_PIPE_WH"
  $$;

-- 単発の動作確認(アラート1件で試す)
SELECT TRY_PARSE_JSON(
  SNOWFLAKE.CORTEX.DATA_AGENT_RUN(
    'DECISION_PIPE_DB.DEMO.DEMAND_ALERT_AGENT',
    $${
      "messages": [
        {"role": "user",
         "content": [{"type": "text",
                      "text": "新宿西口店(店舗ID 1)の「緑茶600ml」(品目ID 102)で、直近30日で予測誤差が最も大きかった日の原因を調べてください。"}]}
      ]
    }$$
  )
) AS resp;
