#!/usr/bin/env python3
"""pipeline.toml の読み取り・スタック preset・検証計画・バージョン操作 (依存ゼロ: Python 3.11+ の tomllib)。

使い方 (すべて repo ルートで。--root で変更可):
  pipeline_config.py get <dotted.key> [--default V]   設定値を 1 つ表示 (無ければ default、無ければ空 + exit 1)
  pipeline_config.py json                              設定全体 (preset をマージした実効値) を JSON で
  pipeline_config.py stacks                            実効スタック一覧 (name / path / verify_always / verify_paths / build_smoke / hosts)
  pipeline_config.py detect                            repo からスタックを検出 (pipeline.toml が無くても動く)
  pipeline_config.py init [--stacks flutter:.,node:web] [--force]   pipeline.toml を生成 (detect 結果を既定に)
  pipeline_config.py plan [--changed FILE|-] [--all]   変更ファイルから実行すべき検証コマンドを JSON で (verify.sh が使う)
  pipeline_config.py forbidden                         禁止パス (既定 + 設定) を JSON で
  pipeline_config.py hosts                             環境に追加すべきホスト (stack + env.extra_hosts)
  pipeline_config.py labels                            ラベル名 (ready / in_progress / merged_unverified / blocked / skipped)
  pipeline_config.py repo                              owner/name (設定 > git remote)
  pipeline_config.py version get|bump <minor|patch|major|X.Y.Z[+N]|+N>   version_stack の版を読む / 上げる (書き換える)
  pipeline_config.py validate                          設定の検証 (exit 1 で問題あり)

設計: docs/pipeline/plugin-plan.md §2.5 (pokemonitor リポジトリ)。
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:  # Python < 3.11
    tomllib = None  # type: ignore

CONFIG_NAME = "pipeline.toml"

# ---------------------------------------------------------------------------------------------
# preset: 省略時の値。pipeline.toml の記述が常に優先する。
#   detect      : (root/path に対して) このスタックとみなす条件
#   verify_always / verify_paths / build_smoke : 検証コマンド (path をカレントにして実行)
#   hosts       : 環境の allowed_hosts に足すもの
#   setup       : setup/<name>.sh テンプレート名 (無ければ setup 不要)
#   version     : 版を持つファイルと形式
# ---------------------------------------------------------------------------------------------
PRESETS: dict[str, dict] = {
    "flutter": {
        "detect": ["pubspec.yaml"],
        "verify_always": ["flutter pub get", "flutter analyze", "timeout 1200 flutter test"],
        "verify_paths": {},
        "build_smoke": {"globs": ["pubspec.*", "android/**"], "cmd": "timeout 1800 flutter build apk --debug && rm -rf build/"},
        "hosts": ["dl.google.com", "maven.google.com"],
        "setup": "flutter",
        "version": {"file": "pubspec.yaml", "kind": "pubspec"},
        "opts": {"flutter_version": "3.41.9", "android_platform": "android-36", "android_build_tools": "36.0.0"},
    },
    "node": {
        "detect": ["package.json"],
        "verify_always": ["npm ci", "npm run lint --if-present", "npm test --if-present", "npm run build --if-present"],
        "verify_paths": {},
        "build_smoke": None,
        "hosts": ["nodejs.org"],
        "setup": "node",
        "version": {"file": "package.json", "kind": "package_json"},
        "opts": {"node_version": "", "npm_version": ""},
    },
    "python": {
        "detect": ["pyproject.toml", "requirements.txt", "requirements-ci.txt"],
        "verify_always": ["__python_install__", "__python_test__"],  # 実行時に uv / pip で解決
        "verify_paths": {},
        "build_smoke": None,
        "hosts": ["astral.sh"],
        "setup": "python",
        "version": {"file": "pyproject.toml", "kind": "pyproject"},
        "opts": {"python_version": "3.12", "requirements": ""},
    },
    "deno": {
        "detect": ["deno.json", "deno.jsonc", "supabase/functions"],
        "verify_always": ["deno lint", "deno test -A"],
        "verify_paths": {},
        "build_smoke": None,
        "hosts": ["deno.land", "dl.deno.land", "jsr.io", "esm.sh"],
        "setup": "deno",
        "version": None,
        "opts": {"deno_version": ""},
    },
    "generic": {
        "detect": [],
        "verify_always": [],
        "verify_paths": {},
        "build_smoke": None,
        "hosts": [],
        "setup": None,
        "version": None,
        "opts": {},
    },
}

DEFAULT_FORBIDDEN = [CONFIG_NAME, ".claude/**", ".github/**", "codemagic.yaml"]
DEFAULT_LABELS = {
    "ready": "pv:ready",
    "in_progress": "pv:in-progress",
    "merged_unverified": "pv:merged-unverified",
    "blocked": "pv:blocked",
    "skipped": "pv:skipped",
    "release": "release",
}
DEFAULTS = {
    "version": 1,
    "kit": "",
    "status_issue": 0,
    "status_issue_title": "#pipeline-status",
    "models": {"session": "fable", "implementer": "opus", "plan_review": "gpt-6-astra"},
    "sweep": {"max_issues": 3, "cron": "0 4,16 * * *", "hours_budget": 2},
    "env": {"name": "", "extra_hosts": [], "extra_apt": [], "extra_lines": [], "vars": {"PIPELINE_ENV": "impl"}},
    "stacks": [],
    "verify": {"forbidden_paths": [], "env": {}, "review_focus": []},
    "merge": {"wait_for_checks": [], "method": "squash"},
    "release": {"version_stack": "", "notes_dir": "release_notes", "providers": []},
}


# ---------------------------------------------------------------------------------------------
def die(msg: str, code: int = 1) -> None:
    print(f"pipeline_config: {msg}", file=sys.stderr)
    sys.exit(code)


def find_root(start: Path) -> Path:
    p = start.resolve()
    for cand in [p, *p.parents]:
        if (cand / CONFIG_NAME).exists() or (cand / ".git").exists():
            return cand
    return p


def load_raw(root: Path) -> dict:
    f = root / CONFIG_NAME
    if not f.exists():
        return {}
    if tomllib is None:
        die("Python 3.11+ (tomllib) が必要です")
    with open(f, "rb") as fh:
        return tomllib.load(fh)


def deep_merge(base, over):
    if isinstance(base, dict) and isinstance(over, dict):
        out = dict(base)
        for k, v in over.items():
            out[k] = deep_merge(base.get(k), v) if k in base else v
        return out
    return over if over is not None else base


def git_repo_slug(root: Path) -> str:
    try:
        url = subprocess.run(["git", "-C", str(root), "config", "--get", "remote.origin.url"], capture_output=True, text=True, check=False).stdout.strip()
    except OSError:
        return ""
    m = re.search(r"github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?/?$", url)
    if m:
        return f"{m.group(1)}/{m.group(2)}"
    # クラウドセッションの origin は proxy URL のことがある → 末尾の owner/name を使う
    m = re.search(r"([^/:]+)/([^/:]+?)(?:\.git)?/?$", url)
    return f"{m.group(1)}/{m.group(2)}" if m else ""


def effective_stacks(cfg: dict) -> list[dict]:
    out = []
    for s in cfg.get("stacks", []):
        name = s.get("name", "generic")
        preset = PRESETS.get(name, PRESETS["generic"])
        opts = dict(preset.get("opts", {}))
        for k, v in s.items():
            if k not in ("name", "path", "verify_always", "verify_paths", "build_smoke", "build_smoke_paths", "hosts"):
                opts[k] = v
        bs = preset.get("build_smoke")
        if "build_smoke" in s:
            bs = {"globs": s.get("build_smoke_paths") or (bs or {}).get("globs") or ["**"], "cmd": s["build_smoke"]} if s["build_smoke"] else None
        out.append({
            "name": name,
            "path": s.get("path", ".") or ".",
            "verify_always": list(s.get("verify_always", preset["verify_always"])),
            "verify_paths": dict(preset.get("verify_paths", {}), **s.get("verify_paths", {})),
            "build_smoke": bs,
            "hosts": list(preset.get("hosts", [])) + list(s.get("hosts", [])),
            "setup": preset.get("setup"),
            "version": preset.get("version"),
            "opts": opts,
        })
    return out


def load(root: Path) -> dict:
    raw = load_raw(root)
    cfg = deep_merge(DEFAULTS, raw)
    cfg["_root"] = str(root)
    cfg["_has_config"] = (root / CONFIG_NAME).exists()
    cfg["repo"] = raw.get("repo") or git_repo_slug(root)
    cfg["labels"] = dict(DEFAULT_LABELS, **raw.get("labels", {}))
    cfg["stacks"] = effective_stacks(cfg)
    if not cfg["env"].get("name"):
        cfg["env"]["name"] = "pipeline-" + "-".join(dict.fromkeys(s["name"] for s in cfg["stacks"])) if cfg["stacks"] else "pipeline-generic"
    if not cfg["release"].get("version_stack") and cfg["stacks"]:
        cfg["release"]["version_stack"] = next((s["name"] for s in cfg["stacks"] if s["version"]), "")
    return cfg


# ---------------------------------------------------------------------------------------------
def detect(root: Path) -> list[dict]:
    """repo を浅く走査してスタックを検出する (深さ 2 まで)。"""
    found: list[dict] = []
    seen = set()

    def consider(d: Path):
        rel = os.path.relpath(d, root).replace("\\", "/")
        rel = "." if rel == "." else rel
        for name, p in PRESETS.items():
            for marker in p["detect"]:
                if (d / marker).exists():
                    if name == "node" and rel != "." and (d / "package.json").exists() and (d.parent / "node_modules").exists():
                        pass
                    key = (name, rel)
                    if key not in seen:
                        seen.add(key)
                        found.append({"name": name, "path": rel})
                    break

    consider(root)
    skip = {".git", "node_modules", "build", ".dart_tool", "third_party", "dist", ".venv", "venv", "__pycache__", ".next"}
    for d1 in sorted(p for p in root.iterdir() if p.is_dir() and p.name not in skip and not p.name.startswith(".")):
        consider(d1)
        for d2 in sorted(p for p in d1.iterdir() if p.is_dir() and p.name not in skip and not p.name.startswith(".")):
            consider(d2)
    # flutter があれば同じ path の python (pubspec と requirements が同居することは無い) はそのまま。deno は supabase/functions のみでも可
    return found


# ---------------------------------------------------------------------------------------------
def _glob_match(path: str, pattern: str) -> bool:
    """`**` を含む glob を fnmatch で近似する (パス区切りは /)。"""
    if pattern.endswith("/**"):
        base = pattern[:-3]
        return path == base or path.startswith(base + "/")
    if pattern.startswith("**/"):
        return fnmatch.fnmatch(path, pattern[3:]) or fnmatch.fnmatch(path, pattern)
    if "**" in pattern:
        return fnmatch.fnmatch(path, pattern.replace("**", "*")) or fnmatch.fnmatch(path, pattern)
    return fnmatch.fnmatch(path, pattern) or fnmatch.fnmatch(path.split("/")[-1], pattern)


def plan(cfg: dict, changed: list[str] | None, run_all: bool, always_only: bool = False) -> dict:
    """変更ファイルから実行するコマンドを決める。戻り値は verify.sh が順に実行する。

    always_only: 全スタックの verify_always だけ (sweep の main 健全性チェック用。paths / build_smoke は回さない)。
    """
    steps: list[dict] = []
    stacks = cfg["stacks"]

    def rel_in(stack: dict, f: str) -> str | None:
        p = stack["path"]
        if p == ".":
            return f
        return f[len(p) + 1:] if f == p or f.startswith(p + "/") else None

    for st in stacks:
        touched = run_all or always_only or changed is None or any(rel_in(st, f) is not None for f in changed)
        if not touched and len(stacks) > 1:
            continue
        for cmd in st["verify_always"]:
            steps.append({"stack": st["name"], "path": st["path"], "kind": "always", "cmd": cmd})
        if always_only:
            continue
        local = [rel_in(st, f) for f in (changed or [])]
        local = [x for x in local if x is not None]
        for glob, cmds in st["verify_paths"].items():
            if run_all or changed is None or any(_glob_match(f, glob) for f in local):
                for cmd in (cmds if isinstance(cmds, list) else [cmds]):
                    steps.append({"stack": st["name"], "path": st["path"], "kind": f"paths:{glob}", "cmd": cmd})
        bs = st["build_smoke"]
        if bs and (run_all or (changed is not None and any(_glob_match(f, g) for f in local for g in bs["globs"]))):
            steps.append({"stack": st["name"], "path": st["path"], "kind": "build_smoke", "cmd": bs["cmd"]})
    return {"steps": steps, "env": cfg["verify"].get("env", {}), "changed": changed}


def forbidden(cfg: dict) -> list[str]:
    return list(dict.fromkeys(DEFAULT_FORBIDDEN + list(cfg["verify"].get("forbidden_paths", []))))


def hosts(cfg: dict) -> list[str]:
    out: list[str] = []
    for st in cfg["stacks"]:
        out += st["hosts"]
    out += cfg["env"].get("extra_hosts", [])
    return list(dict.fromkeys(out))


# ---------------------------------------------------------------------------------------------
_SEMVER = re.compile(r"^(\d+)\.(\d+)\.(\d+)(?:\+(\d+))?$")


def _bump(cur: str, spec: str) -> str:
    m = _SEMVER.match(cur.strip())
    if not m:
        die(f"version '{cur}' is not X.Y.Z[+N]")
    major, minor, patch = int(m.group(1)), int(m.group(2)), int(m.group(3))
    build = int(m.group(4)) if m.group(4) else None
    if _SEMVER.match(spec):
        return spec
    if spec.startswith("+") and spec[1:].isdigit():
        return f"{major}.{minor}.{patch}+{spec[1:]}"
    if spec == "major":
        major, minor, patch = major + 1, 0, 0
    elif spec == "minor":
        minor, patch = minor + 1, 0
    elif spec == "patch":
        patch += 1
    elif spec == "build":
        pass
    else:
        die(f"unknown bump spec '{spec}'")
    if build is not None:
        build += 1
    return f"{major}.{minor}.{patch}" + (f"+{build}" if build is not None else "")


def version_io(cfg: dict, action: str, spec: str | None) -> str:
    st = next((s for s in cfg["stacks"] if s["name"] == cfg["release"]["version_stack"]), None)
    if not st or not st["version"]:
        die("release.version_stack が版を持つスタックを指していません")
    f = Path(cfg["_root"]) / st["path"] / st["version"]["file"]
    kind = st["version"]["kind"]
    text = f.read_text(encoding="utf-8")
    if kind == "pubspec":
        m = re.search(r"^version:\s*([^\s#]+)", text, re.M)
        cur = m.group(1) if m else die("pubspec.yaml に version: が無い")
        sub = lambda new: text[: m.start(1)] + new + text[m.end(1):]
    elif kind == "package_json":
        m = re.search(r'"version"\s*:\s*"([^"]+)"', text)
        cur = m.group(1) if m else die("package.json に version が無い")
        sub = lambda new: text[: m.start(1)] + new + text[m.end(1):]
    elif kind == "pyproject":
        m = re.search(r'^version\s*=\s*"([^"]+)"', text, re.M)
        cur = m.group(1) if m else die("pyproject.toml に version が無い")
        sub = lambda new: text[: m.start(1)] + new + text[m.end(1):]
    else:
        die(f"unknown version kind {kind}")
    if action == "get":
        return cur
    new = _bump(cur, spec or "patch")
    f.write_text(sub(new), encoding="utf-8")
    return f"OLD={cur} NEW={new} FILE={f.relative_to(cfg['_root'])}"


# ---------------------------------------------------------------------------------------------
INIT_TEMPLATE = """# pipeline.toml — 自動実装パイプライン (claude-pipeline プラグイン) の設定。
# リファレンス: https://github.com/{kit_repo}#pipelinetoml
# 省略した項目はプラグインの preset が補う。ここに書いた値が常に優先する。
version = 1
kit = ""                      # /pipeline:setup が書く (環境の setup script と一致させる)
# status_issue = 0            # 省略時はタイトル "#pipeline-status" で検索 (無ければ setup が作る)

[models]
session = "fable"
implementer = "opus"
plan_review = "gpt-6-astra"   # Codex。API 制限時は Fable サブエージェントが代行

[sweep]
max_issues = 3
cron = "0 4,16 * * *"         # UTC (= 13:00 / 01:00 JST)
hours_budget = 2

[env]
# name = "pipeline-{env_name}"  # 省略時は "pipeline-" + stacks 名
extra_hosts = []              # 既定リスト + stack のホストに追加するドメイン
extra_apt = []                # setup で apt-get install するパッケージ
[env.vars]
PIPELINE_ENV = "impl"

{stacks}
[verify]
forbidden_paths = []          # 既定 (pipeline.toml .claude/** .github/** codemagic.yaml) に追加
# review_focus = ["認証", "課金", "データ"]   # 計画レビューで特に見る領域
[verify.env]                  # 検証コマンドに渡すダミー値 (秘密は書かない)

[merge]
wait_for_checks = []          # 例: ["ci-ok"]。既存 CI が緑になるまで待ってから squash

[release]
notes_dir = "release_notes"
# version_stack = "flutter"   # 版を持つ stack (省略時は最初の stack)
# [[release.providers]]
# type = "codemagic"
# workflows = ["android-internal", "ios-testflight"]
"""


def init_config(root: Path, stacks: list[dict] | None, force: bool, kit_repo: str) -> str:
    f = root / CONFIG_NAME
    if f.exists() and not force:
        die(f"{f} は既にあります (--force で上書き)")
    stacks = stacks or detect(root) or [{"name": "generic", "path": "."}]
    blocks = []
    for s in stacks:
        blocks.append(f'[[stacks]]\nname = "{s["name"]}"\npath = "{s["path"]}"\n')
    env_name = "-".join(dict.fromkeys(s["name"] for s in stacks))
    text = INIT_TEMPLATE.format(kit_repo=kit_repo, env_name=env_name, stacks="\n".join(blocks))
    f.write_text(text, encoding="utf-8", newline="\n")
    return str(f)


def validate(cfg: dict) -> list[str]:
    errs = []
    if not cfg["_has_config"]:
        errs.append(f"{CONFIG_NAME} が無い (pipeline_config.py init)")
    if not cfg["repo"]:
        errs.append("repo が決まらない (git remote origin が GitHub でない)")
    if not cfg["stacks"]:
        errs.append("stacks が空")
    for s in cfg["stacks"]:
        if s["name"] not in PRESETS:
            errs.append(f"unknown stack '{s['name']}' (使えるのは {', '.join(PRESETS)})")
        if not (Path(cfg["_root"]) / s["path"]).is_dir():
            errs.append(f"stack {s['name']}: path '{s['path']}' が無い")
    for p in cfg["release"].get("providers", []):
        if "type" not in p:
            errs.append("release.providers に type が無い項目がある")
    if cfg["sweep"]["max_issues"] < 1:
        errs.append("sweep.max_issues は 1 以上")
    return errs


# ---------------------------------------------------------------------------------------------
def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=".", help="repo ルート (既定: カレントから探索)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("get"); g.add_argument("key"); g.add_argument("--default")
    sub.add_parser("json"); sub.add_parser("stacks"); sub.add_parser("detect"); sub.add_parser("forbidden")
    sub.add_parser("hosts"); sub.add_parser("labels"); sub.add_parser("repo"); sub.add_parser("validate")
    i = sub.add_parser("init"); i.add_argument("--stacks"); i.add_argument("--force", action="store_true"); i.add_argument("--kit-repo", default="IkkoKojima/claude-pipeline")
    p = sub.add_parser("plan"); p.add_argument("--changed"); p.add_argument("--all", action="store_true"); p.add_argument("--always", action="store_true", help="全スタックの verify_always だけ")
    v = sub.add_parser("version"); v.add_argument("action", choices=["get", "bump"]); v.add_argument("spec", nargs="?")
    a = ap.parse_args(argv)

    root = find_root(Path(a.root))
    if a.cmd == "detect":
        print(json.dumps(detect(root), ensure_ascii=False)); return 0
    if a.cmd == "init":
        stacks = None
        if a.stacks:
            stacks = [{"name": x.split(":")[0], "path": (x.split(":") + ["."])[1] or "."} for x in a.stacks.split(",") if x]
        print(init_config(root, stacks, a.force, a.kit_repo)); return 0

    cfg = load(root)
    if a.cmd == "get":
        cur = cfg
        for part in a.key.split("."):
            if isinstance(cur, dict) and part in cur:
                cur = cur[part]
            elif isinstance(cur, list) and part.isdigit() and int(part) < len(cur):
                cur = cur[int(part)]
            else:
                if a.default is not None:
                    print(a.default); return 0
                return 1
        print(json.dumps(cur, ensure_ascii=False) if isinstance(cur, (dict, list)) else cur); return 0
    if a.cmd == "json":
        print(json.dumps({k: v for k, v in cfg.items() if not k.startswith("_")}, ensure_ascii=False, indent=1)); return 0
    if a.cmd == "stacks":
        print(json.dumps(cfg["stacks"], ensure_ascii=False, indent=1)); return 0
    if a.cmd == "forbidden":
        print(json.dumps(forbidden(cfg), ensure_ascii=False)); return 0
    if a.cmd == "hosts":
        print(json.dumps(hosts(cfg), ensure_ascii=False)); return 0
    if a.cmd == "labels":
        print(json.dumps(cfg["labels"], ensure_ascii=False)); return 0
    if a.cmd == "repo":
        print(cfg["repo"]); return 0 if cfg["repo"] else 1
    if a.cmd == "validate":
        errs = validate(cfg)
        for e in errs:
            print("NG:", e)
        print("OK" if not errs else f"{len(errs)} problem(s)")
        return 1 if errs else 0
    if a.cmd == "plan":
        changed = None
        if a.changed:
            src = sys.stdin if a.changed == "-" else open(a.changed, encoding="utf-8")
            changed = [l.strip().replace("\\", "/") for l in src if l.strip()]
        print(json.dumps(plan(cfg, changed, a.all, a.always), ensure_ascii=False, indent=1)); return 0
    if a.cmd == "version":
        print(version_io(cfg, a.action, a.spec)); return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
