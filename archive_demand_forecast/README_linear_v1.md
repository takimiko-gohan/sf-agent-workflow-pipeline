# Decision × Cortex Agent パイプライン検証キット

需要予測アラートを題材に、「判定モデルで仕分け → 難しいものだけエージェントで調査 → 品質チェック → 評価」の流れを検証するためのスクリプト一式です。
パイプライン(タスクグラフ)は Pipeline Builder の GUI で組み立てる前提で、それ以外のリソースと各カード用の SQL を用意しています。

## 全体像

```
[10 判定] → [20 ルーティング] → [30 エージェント調査] → [40 品質チェック] → [50 評価]
 Decision     auto / agent        DATA_AGENT_RUN          Decision で          正解ラベルと突合
 モデル                            (agent の行のみ)        根拠を採点          PIPELINE_RUN_LOG へ
```

## フォルダ構成

| ファイル | 実行方法 | 内容 |
|---|---|---|
| `setup/00_setup.sql` | ワークシートで1回 | ロール・WH・DB/スキーマ・権限(ACCOUNTADMIN) |
| `setup/01_synthetic_data.sql` | ワークシートで1回 | 合成データ生成(店舗・品目・天候・実績/予測・アラート・正解ラベル) |
| `setup/02_semantic_view_and_agent.sql` | ワークシートで1回 | セマンティックビューと Cortex Agent |
| `setup/03_pipeline_objects.sql` | ワークシートで1回 | 設定テーブル・出力テーブル・エージェント実行プロシージャ |
| `pipeline/10a_decision_snowflake_decision.sql` | GUI の SQL カード | 判定: snowflake-decision(Private Preview) |
| `pipeline/10b_decision_llm_fallback.sql` | GUI の SQL カード | 判定: 汎用LLM+構造化出力(代替) |
| `pipeline/10c_decision_decider2b.sql` | GUI の SQL カード | 判定: decider-2b(Model Registry→SPCS) |
| `pipeline/20_route.sql` | GUI の SQL カード | ルーティング |
| `pipeline/30_agent_investigation.sql` | GUI の SQL カード | エージェント調査 |
| `pipeline/40a_quality_check_decision.sql` / `40b_...fallback.sql` | GUI の SQL カード | 品質チェックと最終結果 |
| `pipeline/50_evaluate.sql` | GUI の SQL カード | 評価 |
| `setup/99_teardown.sql` | 検証後に1回 | 全削除 |

`10a/10b/10c` と `40a/40b` はどれか1つを使います。判定モデルを差し替えて比較したい場合は、10 のカードだけ入れ替えて再実行してください(`50_evaluate` の結果が `PIPELINE_RUN_LOG` に蓄積されます)。

## 手順

1. `setup/00` → `01` → `02` → `03` を順にワークシートで実行する。
   - `02` の最後の `DATA_AGENT_RUN` で、エージェント単体の応答が返ることを確認する。
2. Workspaces で **DECISION_PIPE_ROLE が所有する共有ワークスペース**を作り、`pipeline/` の SQL ファイルを置く。
3. Pipeline Builder を作成する(DCM プロジェクトの配置先: `DECISION_PIPE_DB.DEMO`)。
4. SQL ファイルのカードを `10 → 20 → 30 → 40 → 50` の順に並べてつなぐ。
   - ウェアハウスは `DECISION_PIPE_WH`、実行ロールは `DECISION_PIPE_ROLE`。
   - 30 のカードはタイムアウトを長めにする(`agent_max_rows` × 90秒程度が目安)。
5. Deploy して手動実行し、`50_evaluate` の出力を確認する。

## 合成データの設計

- 10店舗 × 15品目 × 120日(2026-07-04〜2026-10-31)、計18,000行。
- 直近30日に以下の異常を注入し、予測誤差が40%以上の行をアラート化(約300件)。

| 正解ラベル | 注入内容 |
|---|---|
| `promo` | 販促フラグON、実績 ×1.9 |
| `weather` | 豪雨(全品目 ×0.5、日用品 ×0.8)/ 猛暑(飲料・アイス ×1.8) |
| `stock` | 欠品フラグON、実績 ×0.3 |
| `unknown` | フラグなしで実績 ×1.7 または ×0.4 |

- アラートの約65%は本文に当日状況(販促・欠品・気温・降水量)を含む。残りは「未取得」で、判定モデルだけでは原因を特定できないため、エージェントの調査が必要になる。
- 乱数は HASH ベースなので、何度実行しても同じデータが生成される。
- 正解ラベル(`ALERT_LABELS`、`TRUE_CAUSE`)はセマンティックビューに含めていない。そのため、エージェントは正解を参照できない。

## 調整ポイント

閾値は `PIPELINE_CONFIG` で変更できます。変更後に再実行すれば、新しい値が反映されます。

```sql
UPDATE DECISION_PIPE_DB.DEMO.PIPELINE_CONFIG SET VALUE = 0.9 WHERE KEY = 'auto_conf_min';
```

| KEY | 既定値 | 意味 |
|---|---|---|
| `auto_conf_min` | 0.80 | 原因判定の確信度がこれ以上なら自動確定の候補 |
| `auto_inv_max` | 0.30 | 要調査確率がこれ未満なら自動確定 |
| `agent_max_rows` | 30 | 1回の実行でエージェントに回す上限件数(超過分は人手へ) |
| `quality_min` | 1.20 | 根拠スコア(0〜2)がこれ以上ならエージェントの判定を採用 |

## 未検証・要確認の点

- **snowflake-decision の戻り値の型**:文字列を前提に `TRY_PARSE_JSON` しています。Private Preview のドキュメントで確認してください。
- **decider-2b の応答形式**:`answers` 形式を想定しています。初回は `DECISION_RESULTS.RAW` を見て、パスを確認してください。日本語での精度も未知数です。
- **エージェント定義の `execution_environment`**:Analyst ツールの `tool_resources` に指定しています。エラーになる場合は、該当ブロックを削除してください。
- **汎用LLMのモデル名(`claude-sonnet-5`)**:アカウントやリージョンで使えるものに置き換えてください。
- **DATA_AGENT_RUN の第2引数**:リテラル以外(バインド変数)で渡しています。動かない場合は、プロシージャ内で `EXECUTE IMMEDIATE` による組み立てに変更してください。
