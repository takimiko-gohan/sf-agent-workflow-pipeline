-- =====================================================================
-- 01_synthetic_data.sql
-- 需要予測アラート検証用の合成データを Snowflake 上で生成する
--   ・10店舗 × 15品目 × 120日(2026-07-04〜2026-10-31)の実績と予測
--   ・直近30日に「販促/天候/欠品/原因不明」の異常を注入
--   ・予測誤差40%以上をアラート化し、正解ラベルを別テーブルに保持
-- 乱数は HASH ベースなので、何度流しても同じデータになる(再現性あり)
-- 主キーはセマンティックビュー側で宣言するため、テーブル制約は付けていない
-- =====================================================================

USE ROLE DECISION_PIPE_ROLE;
USE WAREHOUSE DECISION_PIPE_WH;
USE SCHEMA DECISION_PIPE_DB.DEMO;

-- ---------- 決定的な疑似乱数(0〜1) ----------
CREATE OR REPLACE FUNCTION RAND01(k VARCHAR)
RETURNS FLOAT
AS 'ABS(HASH(k)) % 1000000 / 1000000.0';

-- ---------- マスタ ----------
CREATE OR REPLACE TABLE DIM_STORE (
  STORE_ID   NUMBER,
  STORE_NAME VARCHAR,
  REGION     VARCHAR
) COMMENT = '店舗マスタ' AS
SELECT * FROM VALUES
  (1,  '新宿西口店',   '関東'),
  (2,  '渋谷道玄坂店', '関東'),
  (3,  '横浜駅前店',   '関東'),
  (4,  '大宮東口店',   '関東'),
  (5,  '千葉中央店',   '関東'),
  (6,  '梅田北店',     '関西'),
  (7,  '難波南店',     '関西'),
  (8,  '京都四条店',   '関西'),
  (9,  '名古屋栄店',   '中部'),
  (10, '博多駅前店',   '九州');

CREATE OR REPLACE TABLE DIM_ITEM (
  ITEM_ID   NUMBER,
  ITEM_NAME VARCHAR,
  CATEGORY  VARCHAR
) COMMENT = '品目マスタ' AS
SELECT * FROM VALUES
  (101, 'ミネラルウォーター500ml', '飲料'),
  (102, '緑茶600ml',               '飲料'),
  (103, 'スポーツドリンク500ml',   '飲料'),
  (201, 'バニラカップアイス',       'アイス'),
  (202, 'ソーダバー',               'アイス'),
  (203, 'チョコモナカ',             'アイス'),
  (301, '幕の内弁当',               '弁当'),
  (302, '唐揚げ弁当',               '弁当'),
  (303, 'のり弁当',                 '弁当'),
  (401, '食パン6枚切',             'パン'),
  (402, 'メロンパン',               'パン'),
  (403, 'カレーパン',               'パン'),
  (501, 'ティッシュ5箱',           '日用品'),
  (502, '洗濯洗剤',                 '日用品'),
  (503, '歯ブラシ',                 '日用品');

-- ---------- カレンダー ----------
CREATE OR REPLACE TEMPORARY TABLE TMP_CALENDAR AS
SELECT
  DATEADD(day, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, '2026-07-04'::DATE) AS SALES_DATE,
  ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1                                  AS DAY_IDX
FROM TABLE(GENERATOR(ROWCOUNT => 120));

-- 異常を注入する期間(直近30日)
SET anomaly_start = '2026-10-02'::DATE;

-- ---------- 天候(店舗×日) ----------
-- 夏→秋で気温が下がる。直近30日には豪雨・猛暑イベントを注入。
CREATE OR REPLACE TABLE FACT_WEATHER_DAILY (
  STORE_ID     NUMBER,
  SALES_DATE   DATE,
  MAX_TEMP_C   NUMBER(4,1),
  RAIN_MM      NUMBER(5,1),
  WEATHER_EVENT VARCHAR            -- 内部用(セマンティックビューには出さない)
) COMMENT = '店舗別の日次天候' AS
WITH base AS (
  SELECT
    s.STORE_ID, c.SALES_DATE, c.DAY_IDX,
    33 - 13 * (c.DAY_IDX / 119) + (RAND01('t' || s.STORE_ID || c.SALES_DATE) * 6 - 3) AS temp_base,
    IFF(RAND01('r' || s.STORE_ID || c.SALES_DATE) < 0.2,
        1 + RAND01('rm' || s.STORE_ID || c.SALES_DATE) * 19, 0)                     AS rain_base,
    RAND01('wx' || s.STORE_ID || c.SALES_DATE)                                      AS r_wx
  FROM DIM_STORE s CROSS JOIN TMP_CALENDAR c
)
SELECT
  STORE_ID,
  SALES_DATE,
  ROUND(CASE WHEN SALES_DATE >= $anomaly_start AND r_wx < 0.02 THEN 36 + r_wx * 50   -- 猛暑
             ELSE temp_base END, 1)                                                AS MAX_TEMP_C,
  ROUND(CASE WHEN SALES_DATE >= $anomaly_start AND r_wx >= 0.02 AND r_wx < 0.05
             THEN 45 + r_wx * 700                                                   -- 豪雨
             ELSE rain_base END, 1)                                                AS RAIN_MM,
  CASE WHEN SALES_DATE >= $anomaly_start AND r_wx < 0.02 THEN 'heat'
       WHEN SALES_DATE >= $anomaly_start AND r_wx < 0.05 THEN 'heavy_rain'
       ELSE NULL END                                                               AS WEATHER_EVENT
FROM base;

-- ---------- 日次実績と予測(店舗×品目×日) ----------
CREATE OR REPLACE TABLE FACT_SALES_DAILY (
  STORE_ID       NUMBER,
  ITEM_ID        NUMBER,
  SALES_DATE     DATE,
  FORECAST_UNITS NUMBER,
  ACTUAL_UNITS   NUMBER,
  PROMO_FLAG     BOOLEAN,
  STOCKOUT_FLAG  BOOLEAN,
  TRUE_CAUSE     VARCHAR           -- 内部用の正解(セマンティックビューには出さない)
) COMMENT = '店舗×品目の日次の需要予測と販売実績' AS
WITH grid AS (
  SELECT
    s.STORE_ID, i.ITEM_ID, i.CATEGORY, w.SALES_DATE,
    w.MAX_TEMP_C, w.RAIN_MM, w.WEATHER_EVENT,
    20 + RAND01('lvl' || s.STORE_ID || '-' || i.ITEM_ID) * 60                    AS level,
    IFF(DAYOFWEEKISO(w.SALES_DATE) >= 6, 1.2, 1.0)                               AS dow_f,
    RAND01('k' || s.STORE_ID || '-' || i.ITEM_ID || '-' || w.SALES_DATE)         AS key_r
  FROM DIM_STORE s
  CROSS JOIN DIM_ITEM i
  JOIN FACT_WEATHER_DAILY w ON w.STORE_ID = s.STORE_ID
),
expected AS (
  -- 「平常時の天候」を前提にした期待値(予測はイベントを知らない)
  SELECT g.*,
    level * dow_f
      * IFF(CATEGORY IN ('飲料','アイス'), 1 + 0.03 * (LEAST(MAX_TEMP_C, 34) - 25), 1)
      AS exp_units,
    RAND01('ev' || key_r) AS r_ev
  FROM grid g
),
labeled AS (
  SELECT e.*,
    CASE
      WHEN SALES_DATE < $anomaly_start                         THEN 'none'
      WHEN r_ev < 0.012                                        THEN 'stock'
      WHEN r_ev < 0.027                                        THEN 'promo'
      WHEN WEATHER_EVENT = 'heavy_rain'                        THEN 'weather'
      WHEN WEATHER_EVENT = 'heat' AND CATEGORY IN ('飲料','アイス') THEN 'weather'
      WHEN r_ev < 0.035                                        THEN 'unknown'
      ELSE 'none'
    END AS cause
  FROM expected e
)
SELECT
  STORE_ID, ITEM_ID, SALES_DATE,
  GREATEST(ROUND(exp_units * (0.92 + 0.16 * RAND01('f' || key_r))), 0)           AS FORECAST_UNITS,
  GREATEST(ROUND(
    exp_units * (0.9 + 0.2 * RAND01('a' || key_r))
    * CASE cause
        WHEN 'promo'   THEN 1.9
        WHEN 'stock'   THEN 0.3
        WHEN 'weather' THEN IFF(WEATHER_EVENT = 'heat', 1.8,
                               IFF(CATEGORY = '日用品', 0.8, 0.5))
        WHEN 'unknown' THEN IFF(RAND01('u' || key_r) < 0.5, 1.7, 0.4)
        ELSE 1.0 END
  ), 0)                                                                          AS ACTUAL_UNITS,
  cause = 'promo'                                                                AS PROMO_FLAG,
  cause = 'stock'                                                                AS STOCKOUT_FLAG,
  cause                                                                          AS TRUE_CAUSE
FROM labeled;

-- ---------- アラート(予測誤差40%以上) ----------
-- 約65%のアラートには当日状況(販促・欠品・天候)を本文に含める。
-- 残りは「未取得」とし、エージェントが自分で調べる必要があるケースにする。
CREATE OR REPLACE TABLE FORECAST_ALERTS (
  ALERT_ID       NUMBER,
  STORE_ID       NUMBER,
  ITEM_ID        NUMBER,
  SALES_DATE     DATE,
  FORECAST_UNITS NUMBER,
  ACTUAL_UNITS   NUMBER,
  ERROR_RATE     NUMBER(6,3),
  HAS_CONTEXT    BOOLEAN,
  ALERT_TEXT     VARCHAR
) COMMENT = '需要予測の外れ値アラート' AS
WITH a AS (
  SELECT
    f.*, s.STORE_NAME, i.ITEM_NAME, i.CATEGORY, w.MAX_TEMP_C, w.RAIN_MM,
    (f.ACTUAL_UNITS - f.FORECAST_UNITS) / NULLIF(f.FORECAST_UNITS, 0) AS err,
    RAND01('ctx' || f.STORE_ID || '-' || f.ITEM_ID || '-' || f.SALES_DATE) < 0.65 AS has_ctx
  FROM FACT_SALES_DAILY f
  JOIN DIM_STORE s USING (STORE_ID)
  JOIN DIM_ITEM  i USING (ITEM_ID)
  JOIN FACT_WEATHER_DAILY w USING (STORE_ID, SALES_DATE)
  WHERE f.SALES_DATE >= $anomaly_start
    AND f.FORECAST_UNITS >= 5
    AND ABS(f.ACTUAL_UNITS - f.FORECAST_UNITS) / f.FORECAST_UNITS >= 0.4
)
SELECT
  ROW_NUMBER() OVER (ORDER BY SALES_DATE, STORE_ID, ITEM_ID) AS ALERT_ID,
  STORE_ID, ITEM_ID, SALES_DATE, FORECAST_UNITS, ACTUAL_UNITS,
  ROUND(err, 3) AS ERROR_RATE,
  has_ctx       AS HAS_CONTEXT,
  STORE_NAME || '(店舗ID ' || STORE_ID || ')の「' || ITEM_NAME || '」(品目ID ' || ITEM_ID
    || '、カテゴリ: ' || CATEGORY || ')で、' || TO_VARCHAR(SALES_DATE, 'YYYY-MM-DD')
    || 'の販売実績が' || ACTUAL_UNITS || '個、需要予測が' || FORECAST_UNITS || '個でした(誤差 '
    || IFF(err >= 0, '+', '') || ROUND(err * 100) || '%)。'
    || IFF(has_ctx,
         ' 当日状況: 販促' || IFF(PROMO_FLAG, 'あり', 'なし')
         || '、欠品' || IFF(STOCKOUT_FLAG, 'あり', 'なし')
         || '、最高気温' || MAX_TEMP_C || '℃、降水量' || RAIN_MM || 'mm。',
         ' 当日状況: 未取得。')                                   AS ALERT_TEXT
FROM a;

-- 正解ラベル(評価専用。エージェントやセマンティックビューからは参照させない)
CREATE OR REPLACE TABLE ALERT_LABELS (
  ALERT_ID   NUMBER,
  TRUE_CAUSE VARCHAR
) COMMENT = '評価用の正解ラベル' AS
SELECT a.ALERT_ID, f.TRUE_CAUSE
FROM FORECAST_ALERTS a
JOIN FACT_SALES_DAILY f USING (STORE_ID, ITEM_ID, SALES_DATE);

-- ---------- 確認 ----------
SELECT COUNT(*) AS sales_rows FROM FACT_SALES_DAILY;               -- 18,000行
SELECT l.TRUE_CAUSE, a.HAS_CONTEXT, COUNT(*) AS n
FROM FORECAST_ALERTS a JOIN ALERT_LABELS l USING (ALERT_ID)
GROUP BY 1, 2 ORDER BY 1, 2;
SELECT ALERT_TEXT FROM FORECAST_ALERTS ORDER BY ALERT_ID LIMIT 5;
