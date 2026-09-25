#!/bin/bash
# =============================================================================
# claude-pipeline: stack python の SessionStart 処理 (scripts/session_start.sh から呼ばれる)
# 入力 (環境変数): STACK_NAME / STACK_PATH / STACK_OPTS (opts の JSON) / PIPELINE_LOG_DIR
#   - uv.lock があれば uv sync (dev group があれば込み)
#   - 無ければ opts.requirements > requirements-ci.txt > requirements.txt を pip install -r
# 出力は PIPELINE_LOG_DIR に書き、stdout は 1 行だけ。
# =============================================================================
cd "${STACK_PATH:-.}" || exit 0
LOG_DIR="${PIPELINE_LOG_DIR:-${TMPDIR:-/tmp}}"
LOG="$LOG_DIR/python-$(printf '%s' "${STACK_PATH:-.}" | tr -c 'A-Za-z0-9' '_')-deps.log"
say() { echo "[pipeline:python] $*"; }
opt() { python3 -c 'import json,os,sys; v=json.loads(os.environ.get("STACK_OPTS") or "{}").get(sys.argv[1], sys.argv[2]); print("" if v is None else v)' "$1" "$2" 2>/dev/null || printf '%s\n' "$2"; }

if [ -f uv.lock ]; then
  if ! command -v uv >/dev/null 2>&1; then
    say "WARN: uv.lock があるが uv が無い (環境の setup script 未実行?)"; exit 0
  fi
  if { uv sync --group dev 2>/dev/null || uv sync; } > "$LOG" 2>&1; then
    say "uv sync: ok"
  else
    say "WARN: uv sync failed (log: $LOG)"
  fi
  exit 0
fi

REQ="$(opt requirements "")"
if [ -z "$REQ" ]; then
  for f in requirements-ci.txt requirements.txt; do [ -f "$f" ] && { REQ="$f"; break; }; done
fi
if [ -z "$REQ" ]; then
  say "依存ファイル無し (uv.lock / requirements*.txt) → skip"
elif [ ! -f "$REQ" ]; then
  say "WARN: requirements '$REQ' が無い → skip"
else
  # 隔離 venv (.pipeline/venv)。python_version があり uv が使えればその版で作る (無ければ VM の python3)
  VENV=.pipeline/venv; PYVER="$(opt python_version "")"
  if [ ! -x "$VENV/bin/python" ]; then
    if [ -n "$PYVER" ] && command -v uv >/dev/null 2>&1; then
      uv venv --python "$PYVER" "$VENV" > "$LOG" 2>&1 || python3 -m venv "$VENV" >> "$LOG" 2>&1
    else
      python3 -m venv "$VENV" > "$LOG" 2>&1
    fi
  fi
  if [ -x "$VENV/bin/python" ] && { "$VENV/bin/python" -m pip install -q --upgrade pip >/dev/null 2>&1 || true; } \
     && "$VENV/bin/python" -m pip install -q -r "$REQ" >> "$LOG" 2>&1; then
    say "venv ($("$VENV/bin/python" --version 2>&1)) + pip install -r $REQ: ok"
  else
    say "WARN: venv / pip install -r $REQ failed (log: $LOG)"
  fi
fi
exit 0
