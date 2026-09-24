#!/bin/bash
# =============================================================================
# claude-pipeline: stack node の SessionStart 処理 (scripts/session_start.sh から呼ばれる)
# 入力 (環境変数): STACK_NAME / STACK_PATH / STACK_OPTS / PIPELINE_LOG_DIR
# package-lock.json があれば STACK_PATH で npm ci。出力は PIPELINE_LOG_DIR に書き、stdout は 1 行だけ。
# =============================================================================
cd "${STACK_PATH:-.}" || exit 0
LOG_DIR="${PIPELINE_LOG_DIR:-${TMPDIR:-/tmp}}"
LOG="$LOG_DIR/node-$(printf '%s' "${STACK_PATH:-.}" | tr -c 'A-Za-z0-9' '_')-npm-ci.log"
say() { echo "[pipeline:node] $*"; }

if [ -f package-lock.json ]; then
  if npm ci --no-audit --no-fund > "$LOG" 2>&1; then
    say "npm ci: ok (${STACK_PATH:-.}, node $(node --version 2>/dev/null))"
  else
    say "WARN: npm ci failed (log: $LOG)"
  fi
elif [ -f package.json ]; then
  say "package-lock.json が無い (${STACK_PATH:-.}) → npm ci を skip"
fi
exit 0
