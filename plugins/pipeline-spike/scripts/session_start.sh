#!/bin/bash
# Spike: prove that a plugin SessionStart hook runs in a cloud session and that CLAUDE_PLUGIN_ROOT resolves.
OUT=/tmp/pipeline-spike-hook.txt
{
  echo "hook ran at $(date -u +%FT%TZ)"
  echo "CLAUDE_PLUGIN_ROOT=${CLAUDE_PLUGIN_ROOT:-unset}"
  echo "CLAUDE_CODE_REMOTE=${CLAUDE_CODE_REMOTE:-unset}"
  echo "CLAUDE_PROJECT_DIR=${CLAUDE_PROJECT_DIR:-unset}"
  echo "user=$(id -un) pwd=$(pwd)"
} > "$OUT" 2>&1
echo "[pipeline-spike hook] ran; root=${CLAUDE_PLUGIN_ROOT:-unset}; wrote $OUT"
