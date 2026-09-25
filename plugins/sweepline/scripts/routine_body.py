#!/usr/bin/env python3
"""routine (RemoteTrigger ツール) の create / update / run に渡す body を JSON で出す (依存ゼロ)。

Claude が出力をそのまま RemoteTrigger ツールに渡す。API トークンは不要 (RemoteTrigger が認証する)。

使い方 (repo ルートで。--root で変更可):
  routine_body.py create --env-id ENV [--name N] [--model fable] [--cron "0 4,16 * * *"] [--prompt-file F]
                         [--repo owner/name] [--disabled]
      RemoteTrigger create の body。作成直後に必ず clear-connectors の body で update する
      (省くとアカウントの全コネクタが routine に付く)。
  routine_body.py update-prompt --env-id ENV [--model M] [--prompt-file F] [--repo owner/name] [--name N] [--cron C]
      RemoteTrigger update の body。job_config は丸ごと置換されるので全体を出す (--name / --cron は指定時だけ含める)。
  routine_body.py clear-connectors
      {"clear_mcp_connections": true}
  routine_body.py run [--issues 30 31]
      RemoteTrigger run の body: {"text": "issues: 30 31"} / 指定なしは {"text": "sweep"}

既定値は sweepline.toml: name = "<repo 名> sweep"、cron = sweep.cron (UTC)、model = models.session。
prompt は templates/routine-prompt.md の {repo} と {status_issue_title} を置換したもの (先頭の HTML コメントは除く)。
設計: docs/pipeline/plugin-plan.md §3 (pokemonitor リポジトリ)。
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
PLUGIN_ROOT = HERE.parent
DEFAULT_PROMPT = PLUGIN_ROOT / "templates" / "routine-prompt.md"

sys.path.insert(0, str(HERE))
import sweepline_config as pc  # noqa: E402

if hasattr(sys.stderr, "reconfigure"):  # Windows の既定 (cp932) で日本語のメッセージが化けないように
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

MODEL_IDS = {
    "fable": "claude-fable-5-1",
    "opus": "claude-opus-5-5",
    "sonnet": "claude-sonnet-5",
}
ALLOWED_TOOLS = ["Bash", "Read", "Write", "Edit", "Glob", "Grep", "Skill", "Agent", "WebFetch"]
_CRON = re.compile(r"^\S+( \S+){4}$")
_SLUG = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")


def die(msg: str, code: int = 1) -> None:
    print(f"routine_body: {msg}", file=sys.stderr)
    sys.exit(code)


def model_id(name: str) -> str:
    n = (name or "").strip()
    if n.startswith("claude-"):
        return n
    if n.lower() in MODEL_IDS:
        return MODEL_IDS[n.lower()]
    die(f"不明なモデル '{name}' (使えるのは {', '.join(MODEL_IDS)} か claude-* の id)")
    return ""


def repo_slug(cfg: dict, override: str | None) -> str:
    s = (override or cfg.get("repo") or "").strip()
    if not s:
        # クラウドセッションの origin は proxy 経由の URL (…/git/OWNER/REPO) のことがあるので末尾 2 要素で拾う
        try:
            url = subprocess.run(["git", "-C", cfg["_root"], "config", "--get", "remote.origin.url"],
                                 capture_output=True, text=True, check=False).stdout.strip()
        except OSError:
            url = ""
        m = re.search(r"[/:]([^/:]+)/([^/]+?)(?:\.git)?/?$", url)
        s = f"{m.group(1)}/{m.group(2)}" if m else ""
    if not _SLUG.match(s):
        die("repo (owner/name) が決まらない。sweepline.toml に repo = \"owner/name\" を書くか --repo を渡す")
    return s


def render_prompt(path: Path, repo: str, status_title: str) -> str:
    if not path.exists():
        die(f"prompt ファイルが無い: {path}")
    text = path.read_text(encoding="utf-8").replace("\r\n", "\n")
    text = re.sub(r"\A\s*<!--.*?-->\s*", "", text, flags=re.S)  # 先頭の説明コメントは送らない
    text = text.replace("{repo}", repo).replace("{status_issue_title}", status_title).strip()
    if not text:
        die(f"prompt が空: {path}")
    return text


def job_config(env_id: str, model: str, repo: str, prompt: str) -> dict:
    return {
        "ccr": {
            "environment_id": env_id,
            "session_context": {
                "model": model,
                "sources": [{"git_repository": {"url": f"https://github.com/{repo}"}}],
                "allowed_tools": list(ALLOWED_TOOLS),
            },
            "events": [{
                "data": {
                    "uuid": str(uuid.uuid4()),
                    "session_id": "",
                    "type": "user",
                    "parent_tool_use_id": None,
                    "message": {"role": "user", "content": prompt},
                },
            }],
        },
    }


def check_env_id(env_id: str) -> str:
    e = (env_id or "").strip()
    if not e:
        die("--env-id が空")
    if not e.startswith("env_"):
        print(f"routine_body: 注意: environment id '{e}' が env_ で始まらない", file=sys.stderr)
    return e


def check_cron(cron: str) -> str:
    c = " ".join((cron or "").split())
    if not _CRON.match(c):
        die(f"cron は 5 フィールド (UTC): '{cron}'")
    return c


def emit(obj: dict) -> int:
    sys.stdout.buffer.write((json.dumps(obj, ensure_ascii=False, indent=2) + "\n").encode("utf-8"))
    return 0


# ---------------------------------------------------------------------------------------------
def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=".", help="repo ルート (既定: カレントから探索)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    def job_args(p: argparse.ArgumentParser) -> None:
        p.add_argument("--env-id", required=True, help="クラウド環境の id (env_...)")
        p.add_argument("--model", help="fable / opus / sonnet か claude-* の id (既定 models.session)")
        p.add_argument("--prompt-file", help=f"prompt テンプレート (既定 {DEFAULT_PROMPT.relative_to(PLUGIN_ROOT)})")
        p.add_argument("--repo", help="owner/name (既定 sweepline.toml の repo > git remote)")
        p.add_argument("--name", help="routine 名 (既定 '<repo 名> sweep')")
        p.add_argument("--cron", help="cron (UTC、既定 sweep.cron)")

    c = sub.add_parser("create", help="RemoteTrigger create の body")
    job_args(c)
    c.add_argument("--disabled", action="store_true", help="enabled: false で作る")
    u = sub.add_parser("update-prompt", help="RemoteTrigger update の body (job_config 全体)")
    job_args(u)
    sub.add_parser("clear-connectors", help='{"clear_mcp_connections": true}')
    r = sub.add_parser("run", help="RemoteTrigger run の body")
    r.add_argument("--issues", nargs="+", type=int, metavar="N", help="対象 issue 番号 (省略時は通常の sweep)")
    a = ap.parse_args(argv)

    if a.cmd == "clear-connectors":
        return emit({"clear_mcp_connections": True})
    if a.cmd == "run":
        if a.issues:
            if any(n <= 0 for n in a.issues):
                die("issue 番号は正の整数")
            return emit({"text": "issues: " + " ".join(str(n) for n in a.issues)})
        return emit({"text": "sweep"})

    cfg = pc.load(pc.find_root(Path(a.root)))
    repo = repo_slug(cfg, a.repo)
    model = model_id(a.model or cfg["models"].get("session") or "fable")
    status_title = str(cfg.get("status_issue_title") or "#sweepline-status")
    prompt = render_prompt(Path(a.prompt_file) if a.prompt_file else DEFAULT_PROMPT, repo, status_title)
    job = job_config(check_env_id(a.env_id), model, repo, prompt)

    if a.cmd == "create":
        return emit({
            "name": a.name or f"{repo.split('/')[1]} sweep",
            "cron_expression": check_cron(a.cron or cfg["sweep"].get("cron") or "0 4,16 * * *"),
            "enabled": not a.disabled,
            "job_config": job,
        })
    # update-prompt: job_config は丸ごと置換される。name / cron は明示されたときだけ変える
    body: dict = {}
    if a.name:
        body["name"] = a.name
    if a.cron:
        body["cron_expression"] = check_cron(a.cron)
    body["job_config"] = job
    return emit(body)


if __name__ == "__main__":
    sys.exit(main())
