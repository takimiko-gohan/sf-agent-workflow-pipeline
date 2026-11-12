"""
T30_AGENT_ANSWER  [Python ファイル]

ROUTE = 'agent' のチケットを受付順に agent_max_rows 件まで、Cortex Agent(SUPPORT_AGENT)に
1件ずつ渡して回答案を作る。エージェントはヘルプ記事(Cortex Search)と顧客データ(Cortex Analyst)を調べる。

- 1件ごとの失敗は AGENT_RESULTS に status='error' で記録して続行する
- 失敗率が agent_error_max を超えたら例外を投げてタスクを失敗させる(→ T35 が動く)
- シナリオ agent_down(force_agent_failure = 1)では最初に例外を投げる

Pipeline Builder の設定
  種類            : Python file(このファイルを Entrypoint に指定)
  Compute         : Warehouse(DECISION_PIPE_WH)または Compute pool
  Runtime version : 3.11
  Arguments       : なし(必要なら --schema DB.SCHEMA)
  Timeout         : agent_max_rows × 120 秒程度(既定5件なら 600000 ms)
  Predecessors    : T20_ROUTE
  Condition(WHEN): SYSTEM$GET_PREDECESSOR_RETURN_VALUE('T20_ROUTE') <> 'ALL_AUTO'
"""

import argparse
import json
import re
import time

from snowflake.snowpark.context import get_active_session

AGENT_NAME = "DECISION_PIPE_DB.SUPPORT.SUPPORT_AGENT"
META_PATTERN = re.compile(r'\{[^{}]*"resolution"[^{}]*\}')


def load_config(session) -> dict:
    rows = session.sql("SELECT KEY, VALUE FROM PIPELINE_CONFIG").collect()
    return {r["KEY"]: r["VALUE"] for r in rows}


def build_request(received_at, ticket_text: str) -> str:
    text = (
        "次の問い合わせに回答してください。受付日時: "
        + received_at.strftime("%Y-%m-%d %H:%M")
        + "\n"
        + ticket_text
    )
    body = {"messages": [{"role": "user", "content": [{"type": "text", "text": text}]}]}
    return json.dumps(body, ensure_ascii=False)


def parse_answer(resp: str):
    """エージェントの応答から、返信文・resolution・参照記事・使った顧客データを取り出す"""
    j = json.loads(resp)
    answer = "\n".join(
        c.get("text", "") for c in j.get("content", []) if c.get("type") == "text"
    )
    meta = {}
    m = META_PATTERN.search(answer)
    if m:
        try:
            meta = json.loads(m.group(0))
        except json.JSONDecodeError:
            meta = {}
    reply = (answer.replace(m.group(0), "") if m else answer).strip()
    resolution = (meta.get("resolution") or "").lower() or None
    return answer, reply, resolution, meta.get("sources"), meta.get("facts")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--schema", default="DECISION_PIPE_DB.SUPPORT")
    args = parser.parse_args()

    session = get_active_session()
    session.sql(f"USE SCHEMA {args.schema}").collect()

    cfg = load_config(session)
    if cfg.get("force_agent_failure", 0) >= 1:
        raise RuntimeError("強制失敗: シナリオ agent_down")

    max_rows = int(cfg.get("agent_max_rows", 5))
    err_max = float(cfg.get("agent_error_max", 0.5))

    session.sql(
        "DELETE FROM AGENT_RESULTS WHERE TICKET_ID IN (SELECT TICKET_ID FROM CURRENT_BATCH)"
    ).collect()

    targets = session.sql(
        """
        SELECT r.TICKET_ID, r.RECEIVED_AT, r.TICKET_TEXT
        FROM ROUTED_TICKETS r
        JOIN CURRENT_BATCH b ON b.TICKET_ID = r.TICKET_ID
        WHERE r.ROUTE = 'agent' AND r.AGENT_PRIORITY <= ?
        ORDER BY r.AGENT_PRIORITY
        """,
        params=[max_rows],
    ).collect()

    n_ok = n_err = 0
    for row in targets:
        t0 = time.time()
        try:
            body = build_request(row["RECEIVED_AT"], row["TICKET_TEXT"])
            resp = session.sql(
                f"SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN('{AGENT_NAME}', ?)", params=[body]
            ).collect()[0][0]
            answer, reply, resolution, sources, facts = parse_answer(resp)
            session.sql(
                """
                INSERT INTO AGENT_RESULTS
                  (TICKET_ID, STATUS, ANSWER_TEXT, REPLY_TEXT, RESOLUTION, SOURCES, FACTS, RAW_RESPONSE, ELAPSED_MS)
                SELECT ?, 'ok', ?, ?, ?, PARSE_JSON(?), ?, PARSE_JSON(?), ?
                """,
                params=[
                    row["TICKET_ID"], answer, reply, resolution,
                    json.dumps(sources, ensure_ascii=False) if sources is not None else None,
                    facts, resp, int((time.time() - t0) * 1000),
                ],
            ).collect()
            n_ok += 1
        except Exception as e:  # 1件の失敗で止めない
            session.sql(
                """
                INSERT INTO AGENT_RESULTS (TICKET_ID, STATUS, ERROR_MESSAGE, ELAPSED_MS)
                SELECT ?, 'error', ?, ?
                """,
                params=[row["TICKET_ID"], str(e)[:4000], int((time.time() - t0) * 1000)],
            ).collect()
            n_err += 1

    summary = f"ok={n_ok} error={n_err} targets={len(targets)} max_rows={max_rows}"
    print(summary)
    try:
        # Python タスクからタスクの実行情報が取れるかも確認対象。取れなくてもログは残す
        session.sql(
            """
            INSERT INTO PIPELINE_EVENTS (RUN_GROUP_ID, TASK, EVENT, DETAIL)
            SELECT SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_GRAPH_RUN_GROUP_ID'), 'T30_AGENT_ANSWER', 'agent_done', ?
            """,
            params=[summary],
        ).collect()
    except Exception:
        session.sql(
            "INSERT INTO PIPELINE_EVENTS (TASK, EVENT, DETAIL) SELECT 'T30_AGENT_ANSWER', 'agent_done', ?",
            params=[summary + " (task runtime info unavailable)"],
        ).collect()

    if n_ok + n_err > 0 and n_err / (n_ok + n_err) > err_max:
        raise RuntimeError(f"エージェント呼び出しの失敗率が上限を超えた: {summary}")


if __name__ == "__main__":
    main()
