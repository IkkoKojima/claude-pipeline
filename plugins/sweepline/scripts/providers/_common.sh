#!/bin/bash
# providers/_common.sh — provider スクリプトの共通部。各 <type>.sh が PROVIDER_TYPE を決めてから source する (単体では実行しない)。
#
# provider インターフェース (docs/pipeline/plugin-plan.md §2.5)。出力は stdout に KEY=value 行だけ、人向けの補足は stderr:
#   <type>.sh preflight               資格と設定の確認。OK → PREFLIGHT=ok (exit 0) / NG → PREFLIGHT=ng + REASON=... (exit 1)
#   <type>.sh deploy <version> <sha>  配信を起動して ID=<id> を出す (同期で終わる provider は STATUS=finished も出す)
#   <type>.sh status <id>             STATUS=running|finished|failed
#   <type>.sh secrets_list            SECRET=<名前>|<置き場所>|<説明> を 1 行 1 件
#   <type>.sh notes_limits            <チャネル>=<文字数上限> (例 PLAY=500)。制約が無い provider は何も出さない
#
# 設定: sweepline.toml の [[release.providers]] のうち type が一致する最初の項目。PROVIDER_INDEX=<n> (0 始まり) で
#   n 番目を明示できる (同じ type が複数あるとき)。どの provider でも notes_limits = { PLAY = 500 } で上限を上書きできる。
# 置き場所の表記: env_credential:<host> (クラウド環境の API credentials。proxy が注入) / env_var (環境変数) /
#   codemagic_group:<group> (Codemagic の変数グループ、secure) / codemagic_ui:<画面> / github_secret:<owner/repo> /
#   mcp:<connector> (セッション作成時に有効化するコネクタ) / local (owner の PC)

set -euo pipefail

PROVIDERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(dirname "$PROVIDERS_DIR")"
export PYTHONIOENCODING=utf-8

PY="${SWEEPLINE_PYTHON:-}"
if [[ -z "$PY" ]]; then
  if command -v python3 >/dev/null 2>&1; then PY=python3; else PY=python; fi
fi

PROVIDER_TYPE="${PROVIDER_TYPE:-provider}"
PROVIDER_JSON='{}'
HTTP_HEADERS=()
HTTP_CODE=000
HTTP_BODY=""

die()  { echo "$PROVIDER_TYPE: $*" >&2; exit 1; }
warn() { echo "$PROVIDER_TYPE: $*" >&2; }
# kv KEY value... — 改行と CR は空白に潰して 1 行にする
kv() {
  local k="$1" v
  shift
  v="$*"
  v="${v//$'\r'/}"
  v="${v//$'\n'/ }"
  printf '%s=%s\n' "$k" "$v"
}
preflight_ng() { kv PREFLIGHT ng; kv REASON "$*"; exit 1; }
short() { printf '%s' "$1" | tr '\r\n' '  ' | cut -c1-300; }

cfg()   { "$PY" "$SCRIPTS_DIR/sweepline_config.py" ${SWEEPLINE_ROOT:+--root "$SWEEPLINE_ROOT"} "$@" | tr -d '\r'; }
ghapi() { MSYS_NO_PATHCONV=1 gh api "$@"; }
repo_slug() { bash "$SCRIPTS_DIR/gh.sh" repo; }

# release.providers から自分の項目を PROVIDER_JSON に読む (無ければ {})
load_entry() {
  local all
  all="$(cfg get release.providers --default '[]')" || die "sweepline_config.py を実行できない"
  PROVIDER_JSON="$(printf '%s' "$all" | "$PY" -c '
import json, os, sys
typ = sys.argv[1]
raw = sys.stdin.buffer.read().decode("utf-8").strip() or "[]"
lst = json.loads(raw)
if not isinstance(lst, list):
    sys.exit("release.providers が配列でない")
idx = os.environ.get("PROVIDER_INDEX", "").strip()
if idx:
    if not idx.isdigit() or int(idx) >= len(lst):
        sys.exit("PROVIDER_INDEX=%s が範囲外 (release.providers は %d 件)" % (idx, len(lst)))
    e = lst[int(idx)]
    if e.get("type") != typ:
        sys.exit("release.providers[%s] の type は %r (%s ではない)" % (idx, e.get("type"), typ))
else:
    e = next((x for x in lst if isinstance(x, dict) and x.get("type") == typ), {})
sys.stdout.buffer.write(json.dumps(e, ensure_ascii=True).encode("ascii"))
' "$PROVIDER_TYPE")" || die "release.providers を読めない"
}

# pget <key> [default] — 文字列 / 数値 / bool は 1 行、dict は JSON、list は改行区切り (要素に改行を含むなら pget_list)
pget() {
  printf '%s' "$PROVIDER_JSON" | "$PY" -c '
import json, sys
e = json.loads(sys.stdin.buffer.read().decode("utf-8") or "{}")
v = e.get(sys.argv[1])
if v is None or v == "" or v == []:
    out = sys.argv[2] if len(sys.argv) > 2 else ""
elif isinstance(v, bool):
    out = "true" if v else "false"
elif isinstance(v, list):
    out = "\n".join(x if isinstance(x, str) else json.dumps(x, ensure_ascii=False) for x in v)
elif isinstance(v, dict):
    out = json.dumps(v, ensure_ascii=False)
else:
    out = str(v)
sys.stdout.buffer.write(out.encode("utf-8"))
' "$1" ${2+"$2"}
}

# pget_list <key> — list を NUL 区切りで (while IFS= read -r -d '' x; do ...; done < <(pget_list key))
pget_list() {
  printf '%s' "$PROVIDER_JSON" | "$PY" -c '
import json, sys
v = json.loads(sys.stdin.buffer.read().decode("utf-8") or "{}").get(sys.argv[1]) or []
if not isinstance(v, list):
    v = [v]
sys.stdout.buffer.write(b"".join(str(x).encode("utf-8") + b"\0" for x in v))
' "$1"
}

# pget_pairs <key> — dict を「key<TAB>value」行で (value が list / dict なら JSON)
pget_pairs() {
  printf '%s' "$PROVIDER_JSON" | "$PY" -c '
import json, sys
v = json.loads(sys.stdin.buffer.read().decode("utf-8") or "{}").get(sys.argv[1]) or {}
if not isinstance(v, dict):
    sys.exit(0)
out = ""
for k, x in v.items():
    out += "%s\t%s\n" % (k, x if isinstance(x, str) else json.dumps(x, ensure_ascii=False))
sys.stdout.buffer.write(out.encode("utf-8"))
' "$1"
}

# json_get <dotted.path> < json — 値 (文字列はそのまま、他は JSON)。無ければ空。JSON でなければ exit 3
json_get() {
  "$PY" -c '
import json, sys
try:
    cur = json.loads(sys.stdin.buffer.read().decode("utf-8"))
except ValueError:
    sys.exit(3)
for p in sys.argv[1].split("."):
    if isinstance(cur, dict) and p in cur:
        cur = cur[p]
    elif isinstance(cur, list) and p.isdigit() and int(p) < len(cur):
        cur = cur[int(p)]
    else:
        cur = None
        break
if cur is not None:
    sys.stdout.buffer.write((cur if isinstance(cur, str) else json.dumps(cur)).encode("utf-8"))
' "$1"
}

# http_call METHOD URL [JSON_BODY] — 追加ヘッダは配列 HTTP_HEADERS。HTTP_CODE (失敗時 000) / HTTP_BODY をセット。
# 一時ファイルを使わない (Windows の Git Bash で native curl と /tmp のパスがずれるため)
http_call() {
  local method="$1" url="$2" data="${3-}" out=""
  local -a args=(-sS -X "$method" --max-time "${HTTP_TIMEOUT:-60}" -w $'\n%{http_code}')
  if [[ -n "$data" ]]; then args+=(-H 'Content-Type: application/json' --data-binary "$data"); fi
  out="$(curl "${args[@]}" ${HTTP_HEADERS[@]+"${HTTP_HEADERS[@]}"} "$url")" || true
  HTTP_CODE="${out##*$'\n'}"
  HTTP_BODY="${out%$'\n'*}"
  if [[ ! "$HTTP_CODE" =~ ^[0-9]{3}$ ]]; then HTTP_CODE=000; HTTP_BODY="$out"; fi
  if [[ "$out" != *$'\n'* ]]; then HTTP_BODY=""; fi
}

# url_ok URL — 2xx/3xx なら真
url_ok() { curl -fsSL -o /dev/null --max-time "${HTTP_TIMEOUT:-30}" "$1"; }

# utc_iso [minutes_ago] — ISO 8601 (UTC、秒まで)。GNU / BSD date の差を避けて python で
utc_iso() {
  "$PY" -c 'import datetime,sys; t=datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(minutes=int(sys.argv[1])); sys.stdout.write(t.strftime("%Y-%m-%dT%H:%M:%SZ"))' "${1:-0}"
}

# emit_limits "PLAY=500 TESTFLIGHT=4000" — 項目の notes_limits があればそちらを出す
emit_limits() {
  local pairs k v p
  pairs="$(pget_pairs notes_limits)"
  if [[ -n "$pairs" ]]; then
    while IFS=$'\t' read -r k v; do
      [[ -n "$k" ]] || continue
      [[ "$v" =~ ^[0-9]+$ ]] || die "notes_limits.$k が整数でない: $v"
      kv "$(printf '%s' "$k" | tr '[:lower:]' '[:upper:]')" "$v"
    done <<< "$pairs"
    return 0
  fi
  for p in ${1-}; do printf '%s\n' "$p"; done
}

provider_usage() {
  echo "使い方: $(basename "$0") {preflight | deploy <version> <sha> | status <id> | secrets_list | notes_limits}" >&2
  echo "  設定は sweepline.toml の [[release.providers]] (type = \"$PROVIDER_TYPE\")。PROVIDER_INDEX=<n> で項目を明示" >&2
}

provider_main() {
  local fn="${1:-}"
  shift || true
  case "$fn" in
    preflight|deploy|status|secrets_list|notes_limits) ;;
    ""|-h|--help|help) provider_usage; exit 2 ;;
    *) echo "$PROVIDER_TYPE: 不明な関数 '$fn'" >&2; provider_usage; exit 2 ;;
  esac
  load_entry
  "p_$fn" "$@"
}
