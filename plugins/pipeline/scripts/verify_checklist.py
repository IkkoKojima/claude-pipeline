#!/usr/bin/env python3
"""パイプラインの PR 本文スキーマ検証と、リリース時の実機確認チェックリスト生成。

設計: docs/pipeline/cloud-session-pipeline-plan.md §5.1 / §5.3 / §7、plugin-plan.md §2.5 (pokemonitor)

  # マージ前の検証 (/pipeline:impl)。違反があれば exit 1 と理由を stderr に出す
  verify_checklist.py check --pr-body pr_body.md [--changed-files files.txt] [--base origin/main] [--allow-pipeline]

  # リリース用チェックリスト (/pipeline:release)。SINCE..UNTIL のマージ PR と issue から Markdown を生成
  verify_checklist.py generate --since <sha|tag> --until <sha> [--repo owner/name] [--base <branch>] [--out checklist.md]

PR 本文の規約 (check):
  - `Refs #N` 行が 1 つ以上 (1 行に 1 つ)。`Closes/Fixes/Resolves #N` は禁止 (実機確認まで issue を開けておく)
  - `##` 見出し 6 つがこの順で 1 回ずつ、どれも本文が空でない (無ければ「なし」):
    変更点 / テスト結果 / 実機確認の観点 / 判断した点 / Codex 指摘の採否 / Codex 往復
  - 変更ファイルが禁止パス (pipeline_config.py forbidden = 既定 + pipeline.toml verify.forbidden_paths) に当たらない。
    glob: `*` `?` `[..]` は 1 階層内、`**` は階層をまたぐ。`/` を含まないパターンは任意の階層の basename にも当てる。
    末尾 `/*` は配下全体 (`/**`) とみなす (旧形式の互換)。
    --allow-pipeline で既定の 4 つ (pipeline.toml / .claude/** / .github/** / codemagic.yaml) だけ解除 (owner の保守 PR 用)

設定: repo (owner/name) と labels は pipeline_config (同じディレクトリ) から読む。--repo で上書き可。
外部コマンド: git、gh (REST `gh api` のみ。GraphQL を使う gh サブコマンドはクラウドセッションで 403 になるため使わない)。
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.parse
from collections import OrderedDict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pipeline_config as pc  # noqa: E402

REQUIRED_HEADINGS = [
    "## 変更点",
    "## テスト結果",
    "## 実機確認の観点",
    "## 判断した点",
    "## Codex 指摘の採否",
    "## Codex 往復",
]

REFS_RE = re.compile(r"^Refs\s+#(\d+)\s*$", re.MULTILINE)
CLOSES_RE = re.compile(r"\b(close[sd]?|fix(e[sd])?|resolve[sd]?)\s+#\d+", re.IGNORECASE)
FENCE_RE = re.compile(r"^\s*(```|~~~)")


# ---------------------------------------------------------------------------
# glob (`**` あり)
# ---------------------------------------------------------------------------

def _glob_to_regex(pat: str) -> re.Pattern:
    """`**` は階層をまたぐ、`*` `?` `[..]` は 1 階層内。"""
    p = pat.replace("\\", "/").lstrip("/")
    if p.startswith("./"):
        p = p[2:]
    if p.endswith("/*"):  # 旧形式 (tools/pipeline/*) は配下全体
        p = p[:-2] + "/**"
    i, out = 0, []
    while i < len(p):
        c = p[i]
        if p.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif p.startswith("/**", i) and i + 3 == len(p):
            out.append("(?:/.*)?")
            i += 3
        elif p.startswith("**", i):
            out.append(".*")
            i += 2
        elif c == "*":
            out.append("[^/]*")
            i += 1
        elif c == "?":
            out.append("[^/]")
            i += 1
        elif c == "[":
            j = p.find("]", i + 1)
            if j == -1:
                out.append(re.escape(c))
                i += 1
            else:
                cls = p[i + 1:j]
                if cls.startswith("!"):
                    cls = "^" + cls[1:]
                out.append("[" + cls.replace("\\", "\\\\") + "]")
                i = j + 1
        else:
            out.append(re.escape(c))
            i += 1
    return re.compile("".join(out) + r"\Z")


def glob_match(path: str, pattern: str) -> bool:
    path = path.replace("\\", "/")
    if path.startswith("./"):
        path = path[2:]
    rx = _glob_to_regex(pattern)
    if rx.match(path):
        return True
    if "/" not in pattern.strip("/"):  # basename パターンは任意の階層に当てる
        return bool(rx.match(path.rsplit("/", 1)[-1]))
    return False


# ---------------------------------------------------------------------------
# check
# ---------------------------------------------------------------------------

def _headings(body: str) -> list[tuple[int, str]]:
    """(行番号, 見出し行)。コードフェンス内は除く。"""
    out, in_fence = [], False
    for n, ln in enumerate(body.splitlines()):
        if FENCE_RE.match(ln):
            in_fence = not in_fence
            continue
        if not in_fence and ln.startswith("## "):
            out.append((n, ln.rstrip()))
    return out


def _key_of(heading: str) -> str | None:
    return next((r for r in REQUIRED_HEADINGS if heading.startswith(r)), None)


def _sections(body: str) -> dict[str, str]:
    """必須見出しごとの本文 (次の `## ` 見出しまで)。重複時は最初のもの。"""
    lines = body.splitlines()
    hs = _headings(body)
    out: dict[str, str] = {}
    for idx, (n, h) in enumerate(hs):
        key = _key_of(h)
        if not key or key in out:
            continue
        end = hs[idx + 1][0] if idx + 1 < len(hs) else len(lines)
        out[key] = "\n".join(lines[n + 1:end]).strip()
    return out


def _section(body: str, heading: str) -> str:
    return _sections(body or "").get(heading, "")


def check(body: str, changed_files: list[str], allow_pipeline: bool, forbidden: list[str]) -> list[str]:
    errors: list[str] = []
    body = body.replace("\r\n", "\n")
    if not REFS_RE.findall(body):
        errors.append("`Refs #<issue>` 行が無い (1 行に 1 つ)")
    if CLOSES_RE.search(body):
        errors.append("`Closes/Fixes/Resolves #N` は使わない (実機確認まで issue を開けておく)")

    order = [k for k in (_key_of(h) for _, h in _headings(body)) if k]
    counts = {r: order.count(r) for r in REQUIRED_HEADINGS}
    for r in REQUIRED_HEADINGS:
        if counts[r] == 0:
            errors.append(f"見出し `{r}` が無い")
        elif counts[r] > 1:
            errors.append(f"見出し `{r}` が {counts[r]} 回ある")
    if all(counts[r] == 1 for r in REQUIRED_HEADINGS) and order != REQUIRED_HEADINGS:
        errors.append("見出しの順序が規約と違う (" + " / ".join(h[3:] for h in REQUIRED_HEADINGS) + ")")

    secs = _sections(body)
    for r in REQUIRED_HEADINGS:
        if r in secs and not secs[r]:
            errors.append(f"`{r}` の本文が空 (無ければ「なし」と書く)")

    pipeline_own = set(pc.DEFAULT_FORBIDDEN)
    patterns = [p for p in forbidden if not (allow_pipeline and p in pipeline_own)]
    for f in changed_files:
        hit = next((p for p in patterns if glob_match(f, p)), None)
        if hit:
            why = "パイプライン自身の設定 (owner の保守 PR で --allow-pipeline)" if hit in pipeline_own else "pipeline.toml verify.forbidden_paths"
            errors.append(f"禁止パスを変更している: {f} (パターン `{hit}`: {why})")
    return errors


# ---------------------------------------------------------------------------
# generate
# ---------------------------------------------------------------------------

def _run(cmd: list[str], cwd: str | None = None) -> str:
    return subprocess.run(cmd, check=True, capture_output=True, text=True, encoding="utf-8", cwd=cwd).stdout


def _gh_json(path: str, paginate: bool = True) -> list | dict:
    """`gh api` を REST で叩く。--paginate の出力は JSON 配列が連結されて返る (gh 2.45 には
    --slurp が無い) ので raw_decode で順に読んで連結する。"""
    cmd = ["gh", "api", path]
    if paginate:
        cmd += ["--paginate"]
    env = dict(os.environ, MSYS_NO_PATHCONV="1")
    out = subprocess.run(cmd, check=True, capture_output=True, text=True, encoding="utf-8", env=env).stdout.strip()
    if not out:
        return []
    dec = json.JSONDecoder()
    pos = 0
    chunks: list = []
    while pos < len(out):
        while pos < len(out) and out[pos].isspace():
            pos += 1
        if pos >= len(out):
            break
        obj, end = dec.raw_decode(out, pos)
        chunks.append(obj)
        pos = end
    if len(chunks) == 1:
        return chunks[0]
    merged: list = []
    for c in chunks:
        if isinstance(c, list):
            merged.extend(c)
        else:
            merged.append(c)
    return merged


def _default_branch(repo: str) -> str:
    try:
        d = _gh_json(f"repos/{repo}", paginate=False)
        return (d.get("default_branch") if isinstance(d, dict) else None) or "main"
    except subprocess.CalledProcessError:
        return "main"


def generate(repo: str, since: str, until: str, labels: dict, base: str | None, root: str) -> str:
    shas = set(_run(["git", "rev-list", f"{since}..{until}"], cwd=root).split())
    if not shas:
        return f"# 検証チェックリスト\n\n{since}..{until} に commit はありません。\n"
    base = base or _default_branch(repo)
    q = urllib.parse.urlencode({"state": "closed", "base": base, "per_page": 100, "sort": "updated", "direction": "desc"})
    pulls = _gh_json(f"repos/{repo}/pulls?{q}")
    merged = [p for p in pulls if p.get("merged_at") and p.get("merge_commit_sha") in shas]
    covered = {p["merge_commit_sha"] for p in merged}
    # merge commit 方式でマージされた PR は、ブランチ側の commit も範囲に含まれる → PR の commit 一覧で覆う
    for p in merged:
        try:
            for c in _gh_json(f"repos/{repo}/pulls/{p['number']}/commits?per_page=100"):
                covered.add(c["sha"])
        except subprocess.CalledProcessError:
            pass

    by_issue: "OrderedDict[str, list[dict]]" = OrderedDict()
    unregistered: list[dict] = []
    for p in sorted(merged, key=lambda x: x["merged_at"]):
        body = (p.get("body") or "").replace("\r\n", "\n")
        refs = REFS_RE.findall(body)
        entry = {
            "pr": p["number"],
            "title": p["title"],
            "sha": p["merge_commit_sha"][:7],
            "observe": _section(body, "## 実機確認の観点"),
            "decisions": _section(body, "## 判断した点"),
            "codex": _section(body, "## Codex 指摘の採否"),
        }
        if not refs or not entry["observe"]:
            unregistered.append(entry)
        for r in dict.fromkeys(refs):
            by_issue.setdefault(r, []).append(entry)

    # PR の無い commit (直 push / 旧形式)
    orphan = []
    for line in _run(["git", "log", "--format=%H %s", f"{since}..{until}"], cwd=root).splitlines():
        h, _, subj = line.partition(" ")
        if h not in covered:
            orphan.append((h[:7], subj))

    # 持ち越し: merged_unverified ラベルが付いたままで、この範囲の PR に含まれない issue
    carried = []
    mu = labels.get("merged_unverified") or pc.DEFAULT_LABELS["merged_unverified"]
    try:
        q = urllib.parse.urlencode({"state": "open", "labels": mu, "per_page": 100})
        for i in _gh_json(f"repos/{repo}/issues?{q}"):
            if "pull_request" in i:
                continue
            if str(i["number"]) not in by_issue:
                carried.append(i)
    except subprocess.CalledProcessError:
        pass

    out = [f"# 検証チェックリスト ({since}..{until})", ""]
    out.append(f"対象 commit {len(shas)} / マージ PR {len(merged)} / issue {len(by_issue)}")
    out.append("")
    for num, entries in by_issue.items():
        title = ""
        try:
            d = _gh_json(f"repos/{repo}/issues/{num}", paginate=False)
            title = d.get("title", "") if isinstance(d, dict) else ""
        except subprocess.CalledProcessError:
            pass
        out.append(f"## #{num} {title}".rstrip())
        for e in entries:
            out.append(f"- PR #{e['pr']} {e['title']} (`{e['sha']}`)")
            out.append("  - [ ] 実機確認の観点:")
            out.extend(f"    {ln}" for ln in (e["observe"] or "(未記入)").splitlines())
            if e["decisions"] and e["decisions"] != "なし":
                out.append("  - 判断した点:")
                out.extend(f"    {ln}" for ln in e["decisions"].splitlines())
            if e["codex"] and e["codex"] != "なし":
                out.append("  - Codex 指摘の採否 (未解決があれば確認):")
                out.extend(f"    {ln}" for ln in e["codex"].splitlines())
        out.append("")
    if unregistered:
        out.append("## 観点未登録の PR (Refs か「実機確認の観点」が無い)")
        for e in unregistered:
            out.append(f"- PR #{e['pr']} {e['title']} (`{e['sha']}`)")
        out.append("")
    if orphan:
        out.append("## PR の無い commit (直 push / 旧形式)")
        for h, s in orphan:
            out.append(f"- `{h}` {s}")
        out.append("")
    if carried:
        out.append(f"## 持ち越し (前回以前に {mu} のまま)")
        for i in carried:
            out.append(f"- #{i['number']} {i['title']}")
        out.append("")
    return "\n".join(out) + "\n"


# ---------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    for s in (sys.stdout, sys.stderr):
        try:
            s.reconfigure(encoding="utf-8")  # Windows の cp932 回避
        except (AttributeError, ValueError):
            pass
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=".", help="repo ルート (既定: カレントから探索)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check")
    c.add_argument("--pr-body", required=True, help="PR 本文の Markdown ファイル")
    c.add_argument("--changed-files", help="変更ファイル一覧 (1 行 1 パス)。無ければ git diff --name-only <base>...HEAD")
    c.add_argument("--base", default="origin/main", help="--changed-files が無いときの比較元 (既定 origin/main)")
    c.add_argument("--allow-pipeline", action="store_true",
                   help="pipeline.toml / .claude/** / .github/** / codemagic.yaml の変更を許す (owner の保守 PR)")
    g = sub.add_parser("generate")
    g.add_argument("--since", required=True)
    g.add_argument("--until", required=True)
    g.add_argument("--repo", help="owner/name (既定: pipeline_config の repo)")
    g.add_argument("--base", help="PR の base ブランチ (既定: repo の default branch)")
    g.add_argument("--out")
    a = ap.parse_args(argv)

    root = pc.find_root(Path(a.root))
    cfg = pc.load(root)

    if a.cmd == "check":
        body = Path(a.pr_body).read_text(encoding="utf-8")
        if a.changed_files:
            files = [ln.strip() for ln in Path(a.changed_files).read_text(encoding="utf-8").splitlines() if ln.strip()]
        else:
            try:
                files = _run(["git", "diff", "--name-only", f"{a.base}...HEAD"], cwd=str(root)).split("\n")
                files = [f.strip() for f in files if f.strip()]
            except (subprocess.CalledProcessError, OSError) as e:
                # 変更範囲が取れないまま通すと禁止パス検査が素通りになるので止める
                detail = (getattr(e, "stderr", None) or str(e)).strip()
                print(f"変更ファイルを取得できない (git diff --name-only {a.base}...HEAD): {detail}\n--changed-files で渡すか --base を直す",
                      file=sys.stderr)
                return 2
        errs = check(body, files, a.allow_pipeline, pc.forbidden(cfg))
        if errs:
            print("PR 本文 / 変更範囲の検証に失敗:", file=sys.stderr)
            for e in errs:
                print(f"  - {e}", file=sys.stderr)
            return 1
        print(f"ok: 本文の構成と変更範囲 ({len(files)} files) は規約どおり")
        return 0

    repo = a.repo or cfg.get("repo") or ""
    if not repo:
        print("repo が決まらない (pipeline.toml repo / git remote origin / --repo)", file=sys.stderr)
        return 2
    md = generate(repo, a.since, a.until, cfg["labels"], a.base, str(root))
    if a.out:
        Path(a.out).write_text(md, encoding="utf-8", newline="\n")
        print(f"wrote {a.out}")
    else:
        sys.stdout.write(md)
    return 0


if __name__ == "__main__":
    sys.exit(main())
