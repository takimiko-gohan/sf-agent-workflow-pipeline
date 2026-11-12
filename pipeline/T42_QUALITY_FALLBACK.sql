-- =====================================================================
-- T42_QUALITY_FALLBACK  [.sql ファイル]
-- T41(decider-2b)が失敗したときだけ動き、汎用LLMの構造化出力で採点し直す(日本語のまま)。
-- モデル名 'claude-sonnet-5' は自アカウントで AI_COMPLETE に使えるものに置き換える。
--
-- Pipeline Builder の設定
--   種類                  : SQL file(このファイル)
--   Predecessors          : T41_QUALITY_CHECK
--   Condition(WHEN)      : SYSTEM$PREDECESSORS_STATE('ALL_FAILED')
-- =====================================================================
USE SCHEMA DECISION_PIPE_DB.SUPPORT;

DELETE FROM QUALITY_SCORES WHERE TICKET_ID IN (SELECT TICKET_ID FROM CURRENT_BATCH);

INSERT INTO QUALITY_SCORES (TICKET_ID, MODEL, INPUT_LANG, SCORE, RESOLVES, RISK, RAW)
SELECT TICKET_ID, 'llm-fallback', 'ja',
       COALESCE(j0:structured_output[0]:raw_message:score,         j0:score)::FLOAT,
       COALESCE(j0:structured_output[0]:raw_message:resolves_prob, j0:resolves_prob)::FLOAT,
       COALESCE(j0:structured_output[0]:raw_message:risk_prob,     j0:risk_prob)::FLOAT,
       j0
FROM (
  SELECT
    q.TICKET_ID,
    TRY_PARSE_JSON(TO_VARCHAR(AI_COMPLETE(
      model  => 'claude-sonnet-5',
      prompt => 'サポートの返信案を評価してください。\n'
             || 'score: 返信案の内容が参照情報で裏付けられているか(0=裏付けなし・矛盾、1=一部のみ、2=すべて裏付けあり)。\n'
             || 'resolves_prob: 顧客の質問に直接答えている確率(0〜1)。\n'
             || 'risk_prob: 返金・値引き・期日の約束、参照情報にない仕様の断定など、担当者の承認が必要な内容を含む確率(0〜1)。\n'
             || '\n問い合わせ:\n' || q.TICKET_TEXT || '\n\n返信案:\n' || q.REPLY_TEXT || '\n\n参照情報:\n' || q.REFERENCE,
      model_parameters => {'temperature': 0},
      response_format => {
        'type': 'json',
        'schema': {
          'type': 'object',
          'properties': {
            'score': {'type': 'number'},
            'resolves_prob': {'type': 'number'},
            'risk_prob': {'type': 'number'}
          },
          'required': ['score', 'resolves_prob', 'risk_prob']
        }
      }
    ))) AS j0
  FROM QUALITY_CANDIDATES q
  JOIN CURRENT_BATCH b ON b.TICKET_ID = q.TICKET_ID
) ql;
