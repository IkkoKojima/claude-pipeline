#!/bin/bash
# =============================================================================
# sweepline: stack deno の SessionStart 処理 (scripts/session_start.sh から呼ばれる)
# deno は依存を実行時に取得するので準備は不要。ツールの有無だけを 1 行出す。
# =============================================================================
if command -v deno >/dev/null 2>&1; then
  echo "[sweepline:deno] $(deno --version 2>/dev/null | head -1) (session 準備は不要)"
else
  echo "[sweepline:deno] WARN: deno が PATH に無い (環境の setup script 未実行?)"
fi
exit 0
