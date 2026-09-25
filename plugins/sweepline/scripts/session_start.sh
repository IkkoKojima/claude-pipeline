#!/bin/bash
# =============================================================================
# sweepline: SessionStart hook (hooks/hooks.json から起動)。
# クラウドセッション (CLAUDE_CODE_REMOTE=true) 限定で、fresh clone 直後に
#   1) 環境の setup script が書いた SWEEPLINE_ROOT/env.sh を読み、状態を 1 行出す
#   2) sweepline.toml の各 stack について stacks/<name>_session.sh を実行する
#      (依存解決 / native キャッシュ復元 / 温め。環境変数 STACK_NAME / STACK_PATH / STACK_OPTS で渡す)
#   3) Codex CLI に placeholder キーを登録 (実キーは agent proxy が api.openai.com 宛に付与)
#   4) git fetch origin main
# ローカル (CLAUDE_CODE_REMOTE 以外) では何もしないで終わる。常に exit 0。
# stdout は Claude のコンテキストに入るので短く保つ (詳細は SWEEPLINE_ROOT/logs/ に書く)。
# hook の timeout は hooks.json で 900 秒 (stack 側の温めが最大 600 秒)。
# =============================================================================
[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0
cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # = CLAUDE_PLUGIN_ROOT
ROOT="${SWEEPLINE_ROOT:-/opt/sweepline}"; [ -d "$ROOT" ] || ROOT="$HOME/sweepline"
[ -f "$ROOT/env.sh" ] && . "$ROOT/env.sh"
LOG_DIR="$ROOT/logs"
if ! mkdir -p "$LOG_DIR" 2>/dev/null || [ ! -w "$LOG_DIR" ]; then LOG_DIR="${TMPDIR:-/tmp}/sweepline-logs"; mkdir -p "$LOG_DIR"; fi
export SWEEPLINE_ROOT="$ROOT" SWEEPLINE_KIT="$KIT" SWEEPLINE_LOG_DIR="$LOG_DIR"

KIT_SHA="$(cat "$ROOT/kit/.sha" 2>/dev/null)"
REPO_SLUG="$(python3 "$KIT/scripts/sweepline_config.py" repo 2>/dev/null)"
if [ -z "$REPO_SLUG" ]; then
  # origin が github.com 以外 (proxy URL 等) のときは末尾の owner/name で推定する
  REPO_SLUG="$(git remote get-url origin 2>/dev/null | sed -E 's#(\.git)?/*$##; s#^.*[:/]([^/:]+/[^/:]+)$#\1#')"
fi
export SWEEPLINE_REPO="${SWEEPLINE_REPO:-$REPO_SLUG}"

KIT_SHORT="${KIT_SHA:0:12}"
echo "[sweepline] env=${SWEEPLINE_ENV:-unset} kit=${KIT_SHORT:-none} repo=${SWEEPLINE_REPO:-?} branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"

if [ ! -f sweepline.toml ]; then
  echo "[sweepline] WARN: sweepline.toml が無い → stack の準備を skip (ローカルで /sweepline:setup を実行して commit する)"
  exit 0
fi

# ---- stack ごとの準備 ------------------------------------------------------------------------
STACKS_TSV="$(python3 "$KIT/scripts/sweepline_config.py" stacks 2>"$LOG_DIR/stacks.err" \
  | python3 -c 'import json,sys; [print("\t".join([s["name"], s.get("path") or ".", json.dumps(s.get("opts") or {}, ensure_ascii=False)])) for s in json.load(sys.stdin)]' 2>>"$LOG_DIR/stacks.err")"
[ -n "$STACKS_TSV" ] || echo "[sweepline] WARN: stacks を読めない (log: $LOG_DIR/stacks.err)"
while IFS=$'\t' read -r S_NAME S_PATH S_OPTS; do
  [ -n "$S_NAME" ] || continue
  F="$KIT/stacks/${S_NAME}_session.sh"
  [ -f "$F" ] || continue
  if [ ! -d "$S_PATH" ]; then echo "[sweepline:$S_NAME] WARN: path '$S_PATH' が無い → skip"; continue; fi
  STACK_NAME="$S_NAME" STACK_PATH="$S_PATH" STACK_OPTS="$S_OPTS" bash "$F" </dev/null \
    || echo "[sweepline:$S_NAME] WARN: ${S_NAME}_session.sh exit $?"
done <<< "$STACKS_TSV"

# ---- Codex: placeholder キーを登録 (値そのものに意味は無い。api.openai.com 宛の Authorization は
#      環境の API credentials が proxy で差し替える) -------------------------------------------
if command -v codex >/dev/null 2>&1 && [ -n "${OPENAI_API_KEY:-}" ]; then
  printf '%s' "$OPENAI_API_KEY" | codex login --with-api-key >/dev/null 2>&1 || true
fi

git fetch origin main --quiet 2>/dev/null || true
exit 0
