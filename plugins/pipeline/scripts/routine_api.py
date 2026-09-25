#!/usr/bin/env python3
"""routine (claude.ai/code/routines) を API で作成・更新・即時実行する。RemoteTrigger ツールが無い場面 (サブエージェント / 非対話) 用。

endpoint は Claude Code の `RemoteTrigger` ツールと同じ `/v1/code/triggers`。認証は env_api.py と同じローカル OAuth
(~/.claude/.credentials.json)。トークンは表示しない・api.anthropic.com 以外に送らない。

使い方:
  routine_api.py list [--json]                       routine 一覧 (id / name / enabled / cron / env / repo)
  routine_api.py get <trigger_id>
  routine_api.py find <name>                         name が一致する routine の id (無ければ exit 1)
  routine_api.py create --body FILE [--clear-connectors]   作成 (body は routine_body.py create の出力)。作成後にコネクタを外す
  routine_api.py update <trigger_id> --body FILE | --json '{"enabled": false}'   部分更新 (job_config は丸ごと置換なので注意)
  routine_api.py clear-connectors <trigger_id>       全コネクタを外す
  routine_api.py run <trigger_id> [--text "issues: 12 15"]   即時実行 → session id / URL
  routine_api.py ensure --body FILE                  name で探し、無ければ create、あれば job_config を update。常にコネクタを外す。id を表示
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import env_api  # noqa: E402  (同じ OAuth ヘルパを使う)

BASE = "/v1/code/triggers"
TRIGGERS_BETA = "ccr-triggers-2026-01-30"   # RemoteTrigger ツールが付ける beta ヘッダ (環境 API の ccr-byoc とは別)


def _req(method: str, path: str, body: dict | None = None):
    env_api.BETA = TRIGGERS_BETA
    st, b = env_api._req(method, path, body, beta=True)
    if st >= 400:
        raise SystemExit(f"routine_api: {method} {path} -> {st}: {str(b)[:400]}")
    return b


def list_triggers() -> list[dict]:
    b = _req("GET", BASE)
    return b.get("data", []) if isinstance(b, dict) else []


def summarize(t: dict) -> str:
    ccr = (t.get("job_config") or {}).get("ccr") or {}
    repo = ",".join(s.get("git_repository", {}).get("url", "") for s in (ccr.get("session_context") or {}).get("sources", []))
    return f"{t.get('id')}\t{t.get('name')}\tenabled={t.get('enabled')}\tcron={t.get('cron_expression') or '-'}\tenv={ccr.get('environment_id') or '-'}\t{repo}\tconnectors={len(t.get('mcp_connections') or [])}"


def find(name: str) -> dict | None:
    for t in list_triggers():
        if t.get("name") == name:
            return t
    return None


def clear_connectors(tid: str) -> dict:
    return _req("POST", f"{BASE}/{tid}", {"clear_mcp_connections": True}).get("trigger", {})


def main(argv: list[str] | None = None) -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", newline="\n")
        sys.stderr.reconfigure(encoding="utf-8", newline="\n")
    except (AttributeError, ValueError):
        pass
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    l = sub.add_parser("list"); l.add_argument("--json", action="store_true")
    g = sub.add_parser("get"); g.add_argument("trigger_id")
    f = sub.add_parser("find"); f.add_argument("name")
    c = sub.add_parser("create"); c.add_argument("--body", required=True); c.add_argument("--clear-connectors", action="store_true")
    u = sub.add_parser("update"); u.add_argument("trigger_id"); u.add_argument("--body", help="JSON ファイル"); u.add_argument("--json", help="JSON 文字列 (例: '{\"enabled\": false}')")
    cc = sub.add_parser("clear-connectors"); cc.add_argument("trigger_id")
    r = sub.add_parser("run"); r.add_argument("trigger_id"); r.add_argument("--text", default="sweep")
    e = sub.add_parser("ensure"); e.add_argument("--body", required=True)
    a = ap.parse_args(argv)

    if a.cmd == "list":
        ts = list_triggers()
        print(json.dumps(ts, ensure_ascii=False, indent=1) if a.json else "\n".join(summarize(t) for t in ts)); return 0
    if a.cmd == "get":
        print(json.dumps(_req("GET", f"{BASE}/{a.trigger_id}"), ensure_ascii=False, indent=1)); return 0
    if a.cmd == "find":
        t = find(a.name)
        if not t:
            return 1
        print(t["id"]); return 0
    if a.cmd == "create":
        body = json.loads(Path(a.body).read_text(encoding="utf-8"))
        if find(body.get("name", "")):
            raise SystemExit(f"routine_api: 同名の routine が既にある: {body.get('name')} (ensure を使う)")
        t = _req("POST", BASE, body).get("trigger", {})
        if a.clear_connectors:
            t = clear_connectors(t["id"])
        print(summarize(t)); return 0
    if a.cmd == "update":
        if not (a.body or a.json):
            raise SystemExit("routine_api: update には --body FILE か --json '<JSON>' が要る")
        body = json.loads(a.json) if a.json else json.loads(Path(a.body).read_text(encoding="utf-8"))
        print(summarize(_req("POST", f"{BASE}/{a.trigger_id}", body).get("trigger", {}))); return 0
    if a.cmd == "clear-connectors":
        print(summarize(clear_connectors(a.trigger_id))); return 0
    if a.cmd == "run":
        b = _req("POST", f"{BASE}/{a.trigger_id}/run", {"text": a.text})
        sid = b.get("session_id") or ""
        print(f"SESSION_ID={sid}\nURL=https://claude.ai/code/{sid}"); return 0
    if a.cmd == "ensure":
        body = json.loads(Path(a.body).read_text(encoding="utf-8"))
        cur = find(body.get("name", ""))
        if cur:
            _req("POST", f"{BASE}/{cur['id']}", {"job_config": body["job_config"], "cron_expression": body.get("cron_expression"), "enabled": body.get("enabled", True)})
            t = clear_connectors(cur["id"])
        else:
            t = _req("POST", BASE, body).get("trigger", {})
            t = clear_connectors(t["id"])
        print(t["id"]); return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
