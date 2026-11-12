# SaaSカスタマーサポート × Decision × Cortex Agent パイプライン

架空のプロジェクト管理SaaS「TaskFlow」の問い合わせフォームに届いたチケットを分類し、次の3つに振り分けて処理するパイプラインの検証キットです。

| 振り分け | 対象 | 処理 |
|---|---|---|
| **auto** | ヘルプ記事だけで答えられる | 選ばれた記事を根拠に、定型回答を生成する |
| **agent** | ヘルプ記事に加えて、その顧客のデータ確認が必要 | Cortex Agent がヘルプ記事(Cortex Search)と顧客データ(Cortex Analyst)を調べて回答案を作る |
| **human** | 担当者の判断・権限・調査が必要 | 担当者キューに入れ、引き継ぎメモを生成する |

auto と agent の回答も品質チェックにかけます。基準を満たさないものは、下書きを付けて human に回します。

- **判定モデル**:分類と品質チェックには、オープンウェイトの判定モデル **decider-2b**(jev-class decision model、Apache-2.0)を使います。Model Registry に登録し、SPCS のサービスとして SQL から呼び出します。選択肢ごとの確率を返すので、振り分けの閾値を確率で決められます。Snowflake 純正の `snowflake-decision`(AI_COMPLETE)は Private Preview のため使いません。
- **日本語データ**:日本企業での利用を想定し、問い合わせ・返信・顧客データ・ヘルプ記事はすべて日本語です。decider-2b は英語で学習されたモデルなので、パイプラインの中で `AI_TRANSLATE` を使って英訳してから渡します。
- **Pipeline Builder 中心**:処理はすべて Pipeline Builder のカード(タスク)に書いています。プロシージャは使いません。分岐・フォールバック・並列・合流・ファイナライザーも、カードの条件だけで表しています。

---

## 全体像

```mermaid
flowchart TD
  T00["T00_PICK_BATCH<br/>SQL(Scripting)/ root<br/>戻り値: HAS_TICKETS / NO_TICKETS"]
  T05["T05_NO_TICKETS<br/>SQL<br/>空振りログ"]
  T07["T07_TRANSLATE<br/>SQLファイル<br/>AI_TRANSLATE で英訳"]
  T10["T10_CLASSIFY<br/>SQLファイル<br/>decider-2b で分類"]
  T11["T11_CLASSIFY_FALLBACK<br/>SQLファイル<br/>汎用LLMで分類"]
  T20["T20_ROUTE<br/>SQL(Scripting)<br/>戻り値: ALL_AUTO / AGENT / AGENT_OVERFLOW"]
  T30["T30_AGENT_ANSWER<br/>Pythonファイル<br/>エージェントが回答案を作成"]
  T31["T31_OVERFLOW_TO_HUMAN<br/>SQL<br/>上限超過分を担当者へ"]
  T35["T35_AGENT_FAILED<br/>SQL<br/>エージェント対象を担当者へ退避"]
  T40["T40_AUTO_ANSWER<br/>SQLファイル<br/>定型回答の生成・送信候補の作成"]
  T41["T41_QUALITY_CHECK<br/>SQLファイル<br/>decider-2b で品質チェック"]
  T42["T42_QUALITY_FALLBACK<br/>SQLファイル<br/>汎用LLMで品質チェック"]
  T45["T45_FINALIZE<br/>SQL(Scripting)<br/>送信可 / 担当者行きを確定<br/>戻り値: REVIEW_NEEDED / OK"]
  T50["T50_HUMAN_QUEUE<br/>SQLファイル<br/>キュー投入・引き継ぎメモ"]
  T99["T99_RUN_SUMMARY<br/>SQLファイル / finalizer<br/>経路・サマリ記録"]

  T00 -- "= NO_TICKETS" --> T05
  T00 -- "= HAS_TICKETS" --> T07
  T00 -- "= HAS_TICKETS" --> T10
  T07 -- "成否を問わない" --> T10
  T10 -- "ALL_FAILED" --> T11
  T10 --> T20
  T11 --> T20
  T20 -- "≠ ALL_AUTO" --> T30
  T20 -- "= AGENT_OVERFLOW" --> T31
  T30 -- "ALL_FAILED" --> T35
  T20 --> T40
  T30 --> T40
  T31 --> T40
  T35 --> T40
  T40 --> T41
  T41 -- "ALL_FAILED" --> T42
  T41 --> T45
  T42 --> T45
  T45 -- "= REVIEW_NEEDED" --> T50
```

### 検証している Pipeline Builder の機能

| 機能 | 使っている場所 |
|---|---|
| **SQLカード**(1文) | T05、T31、T35 |
| **SQLカード**(Snowflake Scripting のブロック) | T00、T20、T45。戻り値を計算して `SYSTEM$SET_RETURN_VALUE` で設定する |
| **SQLファイル**(.sql、複数文) | T07、T10、T11、T40、T41、T42、T50、T99 |
| **Pythonファイル**(Code Bundle) | T30。エージェントを1件ずつ呼ぶループと、行ごとの例外処理 |
| **戻り値による分岐** | T00 → T05 / T07・T10、T20 → T30 / T31、T45 → T50 |
| **前段の失敗で動くフォールバック**(`ALL_FAILED`) | T11(分類)、T35(エージェント)、T42(品質チェック) |
| **前段の成否を問わない続行**(`ALL_DONE`) | T10(T07 の翻訳が失敗しても日本語のまま分類する) |
| **合流**(`AT_LEAST_ONE_SUCCEEDED`) | T20、T40、T45 |
| **並列** | T30 と T31 |
| **ファイナライザー** | T99。各タスクの成功・失敗・スキップと戻り値を記録する |
| **グラフ Config (JSON)** | T00 が `batch_mode` を読む |

**プレーンな SQL でタスクを失敗させる方法**:SQLファイルでは `RAISE` が使えません。そのため、`SELECT TO_NUMBER(IFF(<条件>, '<メッセージ>', '0'))` という書き方をしています。条件が真のときは文字列を数値に変換しようとして変換エラーになり、タスクが失敗します。エラー文にメッセージが残るので、原因も追えます。シナリオの強制失敗と、「判定結果を1件も解析できなかったら失敗させる」チェックに使っています。

### 判定の中身

**T07:英訳(`AI_TRANSLATE(text, 'ja', 'en')`)**
- 今回のバッチの問い合わせを英訳し、`TICKET_TRANSLATIONS` に保存します。失敗した行は NULL になり、エラー内容も残ります。
- ヘルプ記事のタイトルは、未翻訳のものだけ英訳して `KB_TRANSLATIONS` に蓄積します。
- T07 が失敗しても、T10 は日本語のまま分類を続けます。どちらの言語で渡したかは `CLASSIFY_RESULTS.INPUT_LANG` に記録します。
- `translate_for_decider = 0` にすると英訳せずに日本語のまま渡すので、翻訳の効果を比べられます。

**T10:分類(decider-2b の `DECIDER_2B_SVC!SYSTEM_ONE`、1回の呼び出しで4項目)**

質問文は英語で書いています。

| 項目 | タイプ | 内容 |
|---|---|---|
| `category` | choice | 問い合わせの種類(8区分)。フォームで顧客が選んだ区分は誤っていることがある前提 |
| `kb_article` | choice | 回答に使えるヘルプ記事(18本+none)。選択肢は記事タイトルの英訳から組み立てる |
| `requires_human` | noul | 担当者の判断・権限・調査が必要か(返金、請求への異議、不正アクセス、データ削除、法務、管理者ロックアウト、未知の不具合、強い不満など) |
| `needs_account_data` | noul | その顧客固有のデータ(プラン、シート数、請求、API利用、障害影響)の確認が必要か |

**T20:振り分けのルール**(閾値は `PIPELINE_CONFIG` で変更できます)
- **human**:`requires_human` ≥ 0.5、または分類できなかった
- **auto**:記事が特定でき(確信度 ≥ 0.8)、かつ `needs_account_data` < 0.3
- **agent**:上記以外

**T41:品質チェック(decider-2b)**

問い合わせ・返信案・参照情報を英訳して(問い合わせは T07 の英訳を再利用)、JSON オブジェクトにまとめて STATE として渡します。

| 項目 | タイプ | 送信可の基準(T45) |
|---|---|---|
| `grounded` | score(0〜2) | ≥ 1.2(参照情報で裏付けられているか) |
| `resolves` | noul | ≥ 0.5(質問に直接答えているか) |
| `risky` | noul | < 0.5(返金や期日の約束など、承認が必要な内容を含むか) |

参照情報は、auto なら選ばれたヘルプ記事です。agent ならエージェントが引用したヘルプ記事と、照会した顧客データの要約です。

---

## フォルダ構成

| ファイル | 実行方法 | 内容 |
|---|---|---|
| `setup/00_setup.sql` | ワークシートで1回 | ロール・WH・DB・`SUPPORT` スキーマ・権限 |
| `setup/01_synthetic_data.sql` | ワークシートで1回 | 合成データ(顧客・プラン・請求・API利用・障害・ヘルプ記事・チケット・正解ラベル) |
| `setup/02_search_semantic_view_agent.sql` | ワークシートで1回 | Cortex Search(ヘルプ記事)、セマンティックビュー(顧客データ)、回答エージェント |
| `setup/03_pipeline_objects.sql` | ワークシートで1回 | 設定値・各カードが読み書きするテーブル・確認用ビュー |
| `setup/05_decider_model.sql` | ワークシート + 手元のPC | decider-2b 用のコンピュートプール・外部アクセス・イメージリポジトリ、サービスの確認・停止 |
| `pipeline/T*.sql` / `T*.py` | Pipeline Builder のカード | 1カード1ファイル。冒頭コメントに、カードの種類・前段・条件を記載 |
| `pipeline/scenarios.sql` | ワークシート | 検証シナリオの切り替え |
| `pipeline/inspect.sql` | ワークシート | 経路・回答・担当者キュー・評価指標の確認 |
| `setup/99_teardown.sql` | 検証後に1回 | decider-2b のサービス・モデル・プールと `SUPPORT` スキーマを削除 |

---

## 手順

### A. Snowflake のリソースを作る

1. `setup/00` → `01` → `02` → `03` を順にワークシートで実行する。
   - `02` の Cortex Search はインデックスの作成に少し時間がかかります。動作確認の `SEARCH_PREVIEW` が空なら、少し待ってから再実行してください。
   - `02` の最後の `DATA_AGENT_RUN` で、エージェントが顧客データを照会して回答することを確認してください。

### B. decider-2b を登録してサービスを起動する

公式サンプル [Snowflake-Labs/decision-models-in-snowflake-model-registry](https://github.com/Snowflake-Labs/decision-models-in-snowflake-model-registry) のスクリプトを、作成先だけ変えてそのまま使います。

1. `setup/05_decider_model.sql` の **[1]** をワークシートで実行する(ACCOUNTADMIN が必要です)。
   - GPU プール(`GPU_NV_S`、A10G x1)とビルド用の CPU プールを作ります。
   - あわせて、イメージビルド用の外部アクセス(PyPI / PyTorch のみ)とイメージリポジトリを作ります。
   - `GPU_NV_S` が使えないリージョンでは、ここで失敗します。
2. 手元の PC で公式サンプルを実行する。必要なもの:Python 3.12、Snowflake CLI の接続(**既定ロールを `DECISION_PIPE_ROLE` にする**)、約5GBの空き容量。

```bash
git clone https://github.com/Snowflake-Labs/decision-models-in-snowflake-model-registry
cd decision-models-in-snowflake-model-registry
python3.12 -m venv .venv && .venv/bin/pip install -r python/requirements.txt

# 重み(Mapika/decider-2b、リビジョン固定)をダウンロード
.venv/bin/hf download Mapika/decider-2b --revision 533964dae8be954c5b5e19fa4948e48408094c1e \
  --local-dir models/decider-2b

# 作成先をこのキットのスキーマに向ける
export SNOWFLAKE_CONNECTION_NAME=<DECISION_PIPE_ROLE を既定ロールにした接続名>
export DECIDER_BENCH_DATABASE=DECISION_PIPE_DB DECIDER_BENCH_SCHEMA=SUPPORT

.venv/bin/python python/log_model.py        # DECIDER_2B(バージョン SERVICE)を登録
.venv/bin/python python/create_service.py   # DECIDER_2B_SVC を起動(約15分)
```

   Windows の PowerShell の場合は、次のように読み替えてください。
   - `.venv/bin/` → `.venv\Scripts\`
   - `export A=B` → `$env:A = "B"`
   - 行末の `\` → 1行にまとめる

   サンプルの動作確認は macOS / Linux で行われています。Windows で依存関係のインストールに失敗する場合は、WSL を使ってください。
3. `setup/05_decider_model.sql` の **[2]** を実行する。サービスの状態が `READY` になり、英訳した問い合わせ1件に `answers` が返ることを確認してください。

> **費用に注意**:サービスは最小1インスタンスで起動したままになるため、GPU プールが常時課金されます。検証しない間は `05_decider_model.sql` の **[3]** でサービスとプールを止めてください。

### C. Pipeline Builder でパイプラインを組んで実行する

1. Workspaces で、**DECISION_PIPE_ROLE が所有する共有ワークスペース**に `pipeline/` を置く(個人のワークスペースのファイルはタスクから読めません)。
2. Pipeline Builder を作成する(DCM プロジェクトの配置先は `DECISION_PIPE_DB.SUPPORT`)。
3. 下表のとおりカードを置いてつなぎ、条件を設定する。
   - **カード名(タスク名)は表のとおり大文字で付けてください**。戻り値を参照する条件は、タスク名の大文字・小文字まで一致させる必要があります。
   - **SQL**:ファイルの中身をカードの Source に貼り付けます。
   - **SQLファイル**:ワークスペースのファイルを Source に指定します。
   - **Pythonファイル**:Entrypoint に `T30_AGENT_ANSWER.py` を指定し、Code Bundle を作ります。Compute は Warehouse(Public Preview)か Compute pool、Runtime は 3.11 です。
   - **条件**:GUI で Predecessors の状態を選ぶドロップダウンが出ない場合があります。表の Condition(WHEN)の式を、条件欄にそのまま書いてください。
4. グラフの設定を行う。

| 設定 | 値 |
|---|---|
| Schedule | None(手動実行) |
| Config (JSON) | `{"batch_mode": "daily"}` |
| Task defaults | warehouse = `DECISION_PIPE_WH` |
| リトライ | 0 |
| Finalizer | `T99_RUN_SUMMARY` |

5. Deploy し、`scenarios.sql` で設定を切り替えながら Run して、`inspect.sql` で確認する。

### カードの設定

| カード | 種類 | 前段 | Condition(WHEN) |
|---|---|---|---|
| `T00_PICK_BATCH` | SQL(Scripting) | (root) | - |
| `T05_NO_TICKETS` | SQL | T00 | `SYSTEM$GET_PREDECESSOR_RETURN_VALUE('T00_PICK_BATCH') = 'NO_TICKETS'` |
| `T07_TRANSLATE` | SQLファイル | T00 | `SYSTEM$GET_PREDECESSOR_RETURN_VALUE('T00_PICK_BATCH') = 'HAS_TICKETS'` |
| `T10_CLASSIFY` | SQLファイル | T00, T07 | `SYSTEM$GET_PREDECESSOR_RETURN_VALUE('T00_PICK_BATCH') = 'HAS_TICKETS' AND SYSTEM$PREDECESSORS_STATE('ALL_DONE')` |
| `T11_CLASSIFY_FALLBACK` | SQLファイル | T10 | `SYSTEM$PREDECESSORS_STATE('ALL_FAILED')` |
| `T20_ROUTE` | SQL(Scripting) | T10, T11 | `SYSTEM$PREDECESSORS_STATE('AT_LEAST_ONE_SUCCEEDED')` |
| `T30_AGENT_ANSWER` | Pythonファイル | T20 | `SYSTEM$GET_PREDECESSOR_RETURN_VALUE('T20_ROUTE') <> 'ALL_AUTO'` |
| `T31_OVERFLOW_TO_HUMAN` | SQL | T20 | `SYSTEM$GET_PREDECESSOR_RETURN_VALUE('T20_ROUTE') = 'AGENT_OVERFLOW'` |
| `T35_AGENT_FAILED` | SQL | T30 | `SYSTEM$PREDECESSORS_STATE('ALL_FAILED')` |
| `T40_AUTO_ANSWER` | SQLファイル | T20, T30, T31, T35 | `SYSTEM$PREDECESSORS_STATE('AT_LEAST_ONE_SUCCEEDED')` |
| `T41_QUALITY_CHECK` | SQLファイル | T40 | -(既定の ALL_SUCCEEDED) |
| `T42_QUALITY_FALLBACK` | SQLファイル | T41 | `SYSTEM$PREDECESSORS_STATE('ALL_FAILED')` |
| `T45_FINALIZE` | SQL(Scripting) | T41, T42 | `SYSTEM$PREDECESSORS_STATE('AT_LEAST_ONE_SUCCEEDED')` |
| `T50_HUMAN_QUEUE` | SQLファイル | T45 | `SYSTEM$GET_PREDECESSOR_RETURN_VALUE('T45_FINALIZE') = 'REVIEW_NEEDED'` |
| `T99_RUN_SUMMARY` | SQLファイル | (finalizer) | 設定不可 |

**条件まわりの補足**
- **タイムアウト**:`T30_AGENT_ANSWER` は `agent_max_rows` × 120秒程度にしてください(既定は5件なので 600000 ms)。
- **T10 の前段**:T10 は T00 と T07 の両方を前段にしています。これで T00 の戻り値を参照でき(戻り値は直接の前段からしか読めないため)、`ALL_DONE` によって T07 の成否を問わず実行されます。
- **スキップは失敗に数えない**:前段がスキップされた場合、`ALL_FAILED` は満たされません。そのため、T10 が条件でスキップされたときに T11 が動くことはありません。

### シナリオと期待する経路

| シナリオ(`scenarios.sql`) | 期待する経路 |
|---|---|
| 1. 通常 | T00 → T07 → T10 → T20 → T30 → T40 → T41 → T45 → T50 → T99 |
| 2. 分類の判定モデル障害 | T10 **失敗** → **T11**(汎用LLM)→ T20 → …(`DECIDER_2B_SVC` が無い・起動していない場合は通常の Run でもこの経路) |
| 3. エージェント障害 | T30 **失敗** → **T35** → T40 → T41 → T45(agent の行は human)→ T50 |
| 4. 品質チェックの判定モデル障害 | T41 **失敗** → **T42**(汎用LLM)→ T45 → … |
| 5. 処理量超過 | T20 (AGENT_OVERFLOW) → **T30 と T31 が並列** → T40 → … |
| 6. 処理対象なし | T00 (NO_TICKETS) → **T05** → T99(日曜でチケット0件の日も同じ) |
| 7. 翻訳の効果を比べる | 経路は通常と同じ。`translate_for_decider = 0` で日本語のまま渡し、`inspect.sql` の 15 で比べる |
| 8. 翻訳の失敗 | T07 **失敗** → T10(日本語のまま)→ … |
| 9. 一括処理 | Config `batch_mode: all` で未処理日をまとめて処理する(overflow になりやすい) |

---

## 合成データ

すべて架空のデータで、Snowflake 上で生成します。HASH ベースの乱数なので、何度生成しても同じ結果になります。日本企業向けのサービスを想定し、値はすべて日本語です(列名と、評価用の分類コードは英字のまま)。

| テーブル | 内容 |
|---|---|
| `DIM_ACCOUNT` | 顧客40社(プラン、契約・利用シート数、状態(有効 / 支払遅延)、支払い方法、リージョン(東日本 / 西日本)、更新日) |
| `PLAN_LIMITS` | フリー / スタンダード / ビジネス / エンタープライズ の上限と料金 |
| `FACT_INVOICE` | 有料プランの請求書(2026年5〜9月分、支払済み / 未払い / 支払期限超過) |
| `FACT_API_USAGE_DAILY` | 10月のAPI利用。約3割の顧客で上限超過(429)が発生 |
| `INCIDENTS` | 障害4件(ファイル添付、通知メール、西日本リージョンのログイン、API) |
| `KB_ARTICLES` | ヘルプ記事18本(エージェントの検索対象・定型回答の根拠) |
| `SUPPORT_TICKETS` | 2026-10-02〜10-31 のチケット約220件(平日6〜13件、土日0〜2件) |
| `TICKET_LABELS` | 正解ラベル(評価専用。検索サービス・セマンティックビュー・エージェントからは参照できない) |

**チケットの内訳(正解の処理区分)**
- **kb(約45%)**:パスワード再設定、メンバー招待、タスク復元、エクスポート、Slack連携、APIキー、請求書の宛名、通知メール、添付上限、2段階認証、ダウングレード手順
- **lookup(約28%)**:9月分の請求金額と支払い状況、契約シート数、APIの上限(429)、特定日の障害と復旧時刻、ストレージ上限、請求書払いやSSOが使えるか(プランに依存)
- **human(約27%)**:返金依頼、請求金額への異議、不正ログインの疑い、データの即時削除と証明書、未知の不具合、解約をほのめかす苦情、値引き見積もり、DPA締結、唯一の管理者のロックアウト

**わざと紛らわしくしている点**
- 同じヘルプ記事に関係する問い合わせでも、正解の処理区分が分かれるようにしています。
  - KB002:2段階認証の設定方法は kb、唯一の管理者のロックアウトは human
  - KB017:ダウングレード手順は kb、返金依頼は human
- フォームの区分は2割が誤り(顧客が選び間違えた想定)です。

## 評価指標(`inspect.sql`)

| 指標 | 意味 | 目標 |
|---|---|---|
| `unsafe_automation` | 担当者が必要なのに自動で回答した件数 | **0** |
| `human_recall` | 担当者が必要な問い合わせのうち、human に回せた割合 | 1.0 |
| `automation_rate` | 自動で回答できる問い合わせのうち、実際に自動回答した割合 | 高いほど良い |
| `category_acc` | 種類の分類の正解率 | - |
| `kb_match` | 定型回答で選んだヘルプ記事が正解と一致した割合 | - |
| `fact_hit` | 顧客データが必要な問い合わせの回答に、正しい値(金額・上限・復旧時刻など)が含まれた割合 | - |

`inspect.sql` の 15・16 は翻訳の確認です。15 では、decider-2b に渡した言語(英訳 / 日本語)ごとに、分類・記事選択の正解率と要担当者の確率の分かれ方を比べます。16 では、翻訳の失敗件数と訳文のサンプルを見ます。

`inspect.sql` の 11〜14 は、decider-2b の確率そのものを見るためのクエリです。
- **11・12(確率の較正)**:確率の帯ごとに、実際の正解率と比べます。
- **13(閾値の比較)**:`human_min` の候補ごとに、取りこぼしと人手送りの件数を比べます。
- **14(処理時間)**:1件あたりの処理時間と入力トークン数を見ます。

`fact_hit` は、回答の文字列に期待値が含まれるかだけを見る簡易判定です。「1万回」のような表記の揺れは不一致として数えます。

## 調整ポイント(`PIPELINE_CONFIG`)

| KEY | 既定値 | 意味 |
|---|---|---|
| `human_min` | 0.50 | 要担当者の確率がこれ以上なら、最初から human |
| `auto_conf_min` | 0.80 | ヘルプ記事の確信度がこれ以上なら、定型回答の候補にする |
| `auto_data_max` | 0.30 | 顧客データが必要な確率がこれ未満なら、定型回答にする |
| `agent_max_rows` | 5 | 1回でエージェントに回す上限件数 |
| `agent_error_max` | 0.50 | エージェント呼び出しの失敗率の上限 |
| `quality_min` / `resolves_min` / `risk_max` | 1.20 / 0.50 / 0.50 | 送信可の基準 |
| `translate_for_decider` | 1 | decider-2b に渡す前に英訳する(0 で日本語のまま) |
| `force_classify_failure` / `force_agent_failure` / `force_quality_failure` | 0 | シナリオ用の強制失敗(T10 / T30 / T41) |

安全側に倒したい場合は `human_min` を下げ、自動化率を上げたい場合は `auto_conf_min` を下げます。どちらも `unsafe_automation` と見比べながら調整してください。

---

## 未検証・要確認の点

手元では実行できていないため、実機で次の点を確認してください。

**decider-2b について**
- **翻訳を挟んだときの精度**:decider-2b のモデルカードは英語のみ対応としているため、T07 で英訳してから渡しています。英訳の品質(固有名詞や「シート」などの製品用語の訳し方)が判定に影響します。`inspect.sql` の 15・16 で、訳文と、英訳なしの場合との差を確認してください。
- **翻訳の費用と時間**:AI_TRANSLATE は問い合わせ1件ごとと、品質チェックの対象(返信案・参照情報)ごとに呼び出します。
- **choice の確信度**:`confidence` は「最大確率を一様分布で0、1つに集中で1になるよう換算した値」です。ヘルプ記事は19択なので、`auto_conf_min = 0.8` は最大確率がおよそ0.81以上に相当します。必要に応じて調整してください。
- **score の値**:`score` は段階の番号ではなく期待値(0〜2の小数)で返ります。`quality_min = 1.2` はこの期待値に対する閾値です。
- **戻り値の取り出し方**:ANSWER_JSON の取り出し方は、`decider-ai` 1.6.0 のソース(`systemone.py`)で確認した形式です。サービス関数の戻り値から `out:ANSWER_JSON` を取り出す方法は、公式サンプルの SQL に合わせています。初回は `CLASSIFY_RESULTS.RAW` を見てください。
- **費用**:GPU プール(GPU_NV_S)は、サービスが起動している間ずっと課金されます。

**Pipeline Builder について(今回の検証で確かめたいこと)**
- **Scripting ブロックからの戻り値**:T00・T20・T45 は、SQLカードに Snowflake Scripting のブロックを貼り付け、その中で `SYSTEM$SET_RETURN_VALUE` を呼んでいます。公式ドキュメントの例と同じ形ですが、Pipeline Builder の SQLカードで受け付けられるかは未確認です。受け付けられない場合は、ブロック全体を `EXECUTE IMMEDIATE $$ ... $$` で包んでください。`inspect.sql` の 2 で、`RETURN_VALUE` に値が入っているかも確認してください。
- **SQLファイルの実行コンテキスト**:各ファイルの先頭で `USE SCHEMA` を実行しています。SQLファイルのタスクでこれが効くか、そもそも不要かを確認してください。
- **Python ファイルのタスク**:Warehouse で動かす場合は Public Preview です。Python のタスクから `SYSTEM$TASK_RUNTIME_INFO` が取れるかも確認対象です。取れない場合でも、ログは実行IDなしで残します。
- **`<>` による条件(T30)**:通らない場合は、`= 'AGENT' OR ... = 'AGENT_OVERFLOW'` に変更してください(OR が使えるかもドキュメントには記載がありません)。
- **合流の条件**:合流するカード(T20・T40・T45)は `AT_LEAST_ONE_SUCCEEDED` にしています。既定の `ALL_SUCCEEDED` のままだと、片方の分岐がスキップされたときに動きません。

**その他**
- **埋め込みモデル**:`snowflake-arctic-embed-l-v2.0` を指定しています。リージョンで使えない場合は外してください。
- **汎用LLMのモデル名(`claude-sonnet-5`)**:アカウントやリージョンで使えるものに置き換えてください。T11・T40・T42・T50 に出てきます。
- **障害時のグラフの表示**:フォールバックで処理が完了しても、グラフ実行全体は失敗として表示される可能性があります。
