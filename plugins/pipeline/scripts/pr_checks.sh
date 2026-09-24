#!/bin/bash
# =============================================================================
# PR の既存 CI (merge.wait_for_checks) が緑になるまで待つ。VM で回せない検証 (Docker / Windows / Mac 等) を
# 既存の GitHub Actions に残している repo 用。設計: docs/pipeline/plugin-plan.md §2.5 (pokemonitor)。
#
#   pr_checks.sh wait <pr-number> [--timeout 3600] [--interval 30]
#
# pipeline.toml の [merge] wait_for_checks = ["ci-ok", ...] (check-run 名 or commit status の context) を、
# PR の head SHA について REST でポーリングする (毎回 head SHA を取り直す。push されたら新しい SHA を見る):
#   GET repos/<slug>/pulls/<pr>                      → head.sha
#   GET repos/<slug>/commits/<sha>/check-runs        (--paginate。同名が複数あれば id が最大 = 最新)
#   GET repos/<slug>/commits/<sha>/status            (combined status。context ごとの最新)
#
# 判定と出力 (stdout):
#   wait_for_checks が空              → CHECKS=none                          exit 0
#   全部 success                      → CHECKS=ok                            exit 0
#   どれかが failure / cancelled / timed_out / action_required (status は failure / error)
#                                     → CHECKS=fail NAME=<name>             exit 2
#                                       CONCLUSION=<conclusion>
#                                       DETAILS_URL=<details_url か target_url>
#   それ以外の完了 (neutral / skipped / stale) も success ではないので fail 扱い
#     (needs 先が落ちると集約ジョブは skipped になる。これを緑と数えると壊れた PR をマージしてしまう)
#   --timeout 秒を超えた              → CHECKS=timeout                       exit 3
#                                       PENDING=<まだ終わっていない名前 (空白区切り)>
#   引数 / repo / PR 取得の誤り       → CHECKS=error                         exit 1
#                                       REASON=<理由>
# 経過は stderr に出す。gh api は MSYS_NO_PATHCONV=1 で呼ぶ (Windows Git Bash のパス変換対策)。
# =============================================================================
set -u

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="${PIPELINE_PYTHON:-python3}"
export PYTHONUTF8=1 PYTHONIOENCODING=utf-8

err() { echo "CHECKS=error"; echo "REASON=$1"; exit 1; }
usage() { echo "usage: $0 wait <pr-number> [--timeout 3600] [--interval 30]" >&2; err "usage${1:+: $1}"; }

[ "${1:-}" = "wait" ] || usage
PR="${2:-}"
case "$PR" in ''|*[!0-9]*) usage "pr-number must be a number" ;; esac
shift 2
TIMEOUT=3600; INTERVAL=30
while [ $# -gt 0 ]; do
  case "$1" in
    --timeout) [ $# -ge 2 ] || usage; TIMEOUT="$2"; shift 2 ;;
    --timeout=*) TIMEOUT="${1#*=}"; shift ;;
    --interval) [ $# -ge 2 ] || usage; INTERVAL="$2"; shift 2 ;;
    --interval=*) INTERVAL="${1#*=}"; shift ;;
    *) usage "unknown argument $1" ;;
  esac
done
case "$TIMEOUT" in ''|*[!0-9]*) usage "--timeout must be seconds" ;; esac
case "$INTERVAL" in ''|*[!0-9]*|0) usage "--interval must be seconds (>0)" ;; esac

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cfg() { "$PY" "$KIT/scripts/pipeline_config.py" --root "$ROOT" "$@" 2>/dev/null | tr -d '\r'; }
ghapi() { MSYS_NO_PATHCONV=1 gh api "$@"; }
TAB=$'\t'

# 待つ名前 (1 行 1 つ)
NAMES="$(cfg get merge.wait_for_checks --default '[]' | "$PY" -c 'import json,sys
try: v=json.loads(sys.stdin.read() or "[]")
except Exception: v=[]
v=v if isinstance(v,list) else [v]
sys.stdout.write("".join(str(x).strip()+"\n" for x in v if str(x).strip()))')"
if [ -z "$NAMES" ]; then
  echo "CHECKS=none"; exit 0
fi

command -v gh >/dev/null 2>&1 || err "gh CLI not found"
SLUG="$(cfg repo)"; [ -n "$SLUG" ] || SLUG="${PIPELINE_REPO:-}"
[ -n "$SLUG" ] || err "repo slug unknown (pipeline.toml repo / git remote / PIPELINE_REPO)"

TMP="$(mktemp -d 2>/dev/null || mktemp -d -t prchecks)"
trap 'rm -rf "$TMP"' EXIT
printf '%s\n' "$NAMES" > "$TMP/names.txt"

echo "pr_checks: $SLUG PR #$PR を待つ: $(printf '%s' "$NAMES" | tr '\n' ' ')(timeout ${TIMEOUT}s, interval ${INTERVAL}s)" >&2

START=$SECONDS
LAST_SHA=""
while :; do
  SHA="$(ghapi "repos/$SLUG/pulls/$PR" --jq '.head.sha' 2>"$TMP/err.txt" | tr -d '\r')"
  if [ -z "$SHA" ]; then
    if [ -z "$LAST_SHA" ]; then
      err "cannot read PR #$PR of $SLUG: $(head -c 300 "$TMP/err.txt" | tr '\n' ' ')"
    fi
    echo "pr_checks: PR の取得に失敗 (一時的とみなして続行): $(head -c 200 "$TMP/err.txt" | tr '\n' ' ')" >&2
    SHA="$LAST_SHA"
  fi
  if [ -n "$LAST_SHA" ] && [ "$SHA" != "$LAST_SHA" ]; then
    echo "pr_checks: head が変わった ${LAST_SHA:0:7} -> ${SHA:0:7}" >&2
  fi
  LAST_SHA="$SHA"

  : > "$TMP/runs.json"; : > "$TMP/status.json"
  ghapi "repos/$SLUG/commits/$SHA/check-runs?per_page=100" --paginate > "$TMP/runs.json" 2>"$TMP/err.txt" \
    || echo "pr_checks: check-runs の取得に失敗 (続行): $(head -c 200 "$TMP/err.txt" | tr '\n' ' ')" >&2
  ghapi "repos/$SLUG/commits/$SHA/status?per_page=100" > "$TMP/status.json" 2>"$TMP/err.txt" \
    || echo "pr_checks: status の取得に失敗 (続行): $(head -c 200 "$TMP/err.txt" | tr '\n' ' ')" >&2

  # 1 行 1 名前: <ok|pending|fail>\t<name>\t<conclusion>\t<url>
  EVAL="$("$PY" - "$TMP/names.txt" "$TMP/runs.json" "$TMP/status.json" <<'PY'
import json, sys

def load_concat(path):
    try:
        s = open(path, encoding="utf-8").read()
    except OSError:
        return []
    dec, pos, out = json.JSONDecoder(), 0, []
    while True:  # gh --paginate は JSON を連結して出す (--slurp が無い gh もある)
        while pos < len(s) and s[pos].isspace():
            pos += 1
        if pos >= len(s):
            break
        try:
            obj, pos = dec.raw_decode(s, pos)
        except ValueError:
            break
        out.append(obj)
    return out

names = [l.strip() for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
runs = []
for page in load_concat(sys.argv[2]):
    if isinstance(page, dict):
        runs.extend(page.get("check_runs") or [])
statuses = []
for page in load_concat(sys.argv[3]):
    if isinstance(page, dict):
        statuses.extend(page.get("statuses") or [])

FAIL = {"failure", "cancelled", "timed_out", "action_required"}
lines = []
for n in names:
    cand = [r for r in runs if r.get("name") == n]
    if cand:
        r = max(cand, key=lambda x: x.get("id") or 0)
        url = r.get("details_url") or r.get("html_url") or ""
        if r.get("status") != "completed":
            lines.append(("pending", n, r.get("status") or "", url))
        elif r.get("conclusion") == "success":
            lines.append(("ok", n, "success", url))
        else:
            c = r.get("conclusion") or "unknown"
            lines.append(("fail", n, c if c in FAIL else c + " (not success)", url))
        continue
    st = [s for s in statuses if s.get("context") == n]
    if st:
        s = max(st, key=lambda x: (x.get("updated_at") or "", x.get("id") or 0))
        state = s.get("state") or ""
        url = s.get("target_url") or ""
        if state == "success":
            lines.append(("ok", n, "success", url))
        elif state in ("failure", "error"):
            lines.append(("fail", n, state, url))
        else:
            lines.append(("pending", n, state, url))
        continue
    lines.append(("pending", n, "not reported yet", ""))
sys.stdout.buffer.write("".join("\t".join(x) + "\n" for x in lines).encode("utf-8"))
PY
)"
  FAIL_LINE="$(printf '%s\n' "$EVAL" | grep "^fail${TAB}" | head -n 1)"
  if [ -n "$FAIL_LINE" ]; then
    IFS=$'\t' read -r _ name conclusion url <<< "$FAIL_LINE"
    echo "CHECKS=fail NAME=$name"
    echo "CONCLUSION=$conclusion"
    echo "DETAILS_URL=$url"
    echo "SHA=$SHA"
    exit 2
  fi
  PENDING="$(printf '%s\n' "$EVAL" | awk -F'\t' '$1 != "ok" && NF > 0 { print $2 }' | tr '\n' ' ' | sed 's/ $//')"
  if [ -z "$PENDING" ] && [ -n "$EVAL" ]; then
    echo "CHECKS=ok"
    echo "SHA=$SHA"
    exit 0
  fi
  elapsed=$((SECONDS - START))
  echo "pr_checks: ${elapsed}s ${SHA:0:7} 待ち: $(printf '%s\n' "$EVAL" | awk -F'\t' '$1 != "ok" && NF > 0 { printf "%s[%s] ", $2, $3 }')" >&2
  if [ $elapsed -ge "$TIMEOUT" ]; then
    echo "CHECKS=timeout"
    echo "PENDING=$PENDING"
    echo "SHA=$SHA"
    exit 3
  fi
  sleep_for=$INTERVAL
  [ $((elapsed + sleep_for)) -gt "$TIMEOUT" ] && sleep_for=$((TIMEOUT - elapsed))
  [ "$sleep_for" -gt 0 ] && sleep "$sleep_for"
done
