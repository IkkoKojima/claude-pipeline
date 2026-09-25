#!/bin/bash
# =============================================================================
# 変更ファイルから検証コマンドを決めて順に実行する (stack adapter の振り分け)。
# 実行計画は sweepline_config.py plan が sweepline.toml (stacks / verify_always / verify_paths /
# build_smoke / verify.env) から作る。設計: docs/pipeline/plugin-plan.md §2.5 / §3 (pokemonitor)。
#
#   verify.sh [--changed FILE | --all] [--base origin/main]
#
#   --changed FILE  変更ファイル一覧 (1 行 1 パス、repo ルート相対。`-` で stdin)
#   --all           変更に関係なく全スタックの全検証 (verify_paths / build_smoke 含む)
#   --base REF      どちらも無いときの比較元 (既定 origin/main)。
#                   変更 = `git diff --name-only REF...HEAD` + 未コミット (git status --porcelain)。
#                   REF が解決できなければ警告して --all 相当で実行する (検証を減らす方向には倒さない)
#
# 環境変数:
#   SWEEPLINE_VERIFY_TIMEOUT  各ステップ全体の上限 (timeout(1) の書式。例 1800 / 30m)。既定なし
#                            (preset のコマンドは自前の `timeout` を持っている)
#   SWEEPLINE_PYTHON          python 実行ファイル (既定 python3)
#
# 特殊コマンド (python preset):
#   __python_install__  uv.lock → `uv sync --group dev || uv sync` / requirements-ci.txt → pip install -r /
#                       requirements.txt → pip install -r / どれも無ければ何もしない
#   __python_test__     tests/ test/ pytest.ini pyproject.toml のどれかがあれば uv run pytest -q (uv.lock あり)
#                       か python3 -m pytest -q。無ければ "no tests"。pytest の exit 5 (収集 0 件) も成功扱い
#
# 出力: 各ステップの出力を stdout にそのまま流し、.sweepline/verify/<n>-<stack>-<kind>.log にも保存する
#   (実行前に同ディレクトリの古い *.log は消す)。最後に表 (summary.txt にも保存) と 1 行:
#     VERIFY=ok|fail STEPS=<n> FAILED=<m>
#   失敗が 1 つでもあれば exit 1 (途中で止めず全ステップ回す)。sweepline.toml が無いときも exit 1。
# =============================================================================
set -u

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="${SWEEPLINE_PYTHON:-python3}"
export PYTHONUTF8=1 PYTHONIOENCODING=utf-8

usage() {
  echo "usage: $0 [--changed FILE | --all | --always] [--base origin/main]" >&2
  exit 2
}

CHANGED_SRC=""; RUN_ALL=0; RUN_ALWAYS=0; BASE="origin/main"
while [ $# -gt 0 ]; do
  case "$1" in
    --changed) [ $# -ge 2 ] || usage; CHANGED_SRC="$2"; shift 2 ;;
    --changed=*) CHANGED_SRC="${1#*=}"; shift ;;
    --all) RUN_ALL=1; shift ;;
    --always) RUN_ALWAYS=1; shift ;;   # 全 stack の verify_always だけ (sweep の main 健全性チェック)
    --base) [ $# -ge 2 ] || usage; BASE="$2"; shift 2 ;;
    --base=*) BASE="${1#*=}"; shift ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}" >&2; exit 0 ;;
    *) echo "verify.sh: unknown argument: $1" >&2; usage ;;
  esac
done
if [ -n "$CHANGED_SRC" ] && [ $RUN_ALL -eq 1 ]; then
  echo "verify.sh: --changed と --all は同時に指定できない" >&2; usage
fi

# 相対パスの --changed FILE はカレントで読むので cd より先に読む
CHANGED=""
if [ -n "$CHANGED_SRC" ]; then
  if [ "$CHANGED_SRC" = "-" ]; then
    CHANGED="$(cat)"
  elif [ -f "$CHANGED_SRC" ]; then
    CHANGED="$(cat "$CHANGED_SRC")"
  else
    echo "verify.sh: --changed のファイルが無い: $CHANGED_SRC" >&2; exit 2
  fi
fi

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT" || exit 2
if [ ! -f sweepline.toml ]; then
  echo "verify.sh: $ROOT/sweepline.toml が無い (sweepline_config.py init で作る)" >&2
  echo "VERIFY=fail STEPS=0 FAILED=0"
  exit 1
fi

LOG_DIR=".sweepline/verify"
mkdir -p "$LOG_DIR"
rm -f "$LOG_DIR"/*.log 2>/dev/null

# ---- 変更ファイル -------------------------------------------------------------------------
normalize() { tr -d '\r' | sed -e 's#\\#/#g' -e 's#^\./##' -e '/^[[:space:]]*$/d' | grep -v '^\.sweepline/' | sort -u; }

MODE="changed"
if [ $RUN_ALWAYS -eq 1 ]; then
  MODE="always"
elif [ $RUN_ALL -eq 1 ]; then
  MODE="all"
elif [ -z "$CHANGED_SRC" ]; then
  if git rev-parse --verify -q "$BASE^{commit}" >/dev/null 2>&1; then
    CHANGED="$( {
      git diff --name-only "$BASE...HEAD"
      # 未コミット (rename は "old -> new" の new 側)
      git status --porcelain | sed -E 's/^.{3}//; s/^.* -> //; s/^"(.*)"$/\1/'
    } )"
  else
    echo "verify.sh: 警告: base '$BASE' が解決できない → 全検証 (--all) で実行する" >&2
    MODE="all"
  fi
fi
CHANGED="$(printf '%s\n' "$CHANGED" | normalize)"
if [ "$MODE" = changed ]; then
  printf '%s\n' "$CHANGED" > "$LOG_DIR/changed.txt"
fi

# ---- 計画 ---------------------------------------------------------------------------------
PLAN_JSON="$LOG_DIR/plan.json"
if [ "$MODE" = always ]; then
  "$PY" "$KIT/scripts/sweepline_config.py" --root "$ROOT" plan --always > "$PLAN_JSON" || { echo "verify.sh: plan の生成に失敗" >&2; echo "VERIFY=fail STEPS=0 FAILED=0"; exit 1; }
elif [ "$MODE" = all ]; then
  "$PY" "$KIT/scripts/sweepline_config.py" --root "$ROOT" plan --all > "$PLAN_JSON" || { echo "verify.sh: plan の生成に失敗" >&2; echo "VERIFY=fail STEPS=0 FAILED=0"; exit 1; }
else
  printf '%s\n' "$CHANGED" | "$PY" "$KIT/scripts/sweepline_config.py" --root "$ROOT" plan --changed - > "$PLAN_JSON" \
    || { echo "verify.sh: plan の生成に失敗" >&2; echo "VERIFY=fail STEPS=0 FAILED=0"; exit 1; }
fi

# plan.json → bash の配列と export 文 (shlex.quote で安全に)。Windows の改行変換を避けるため bytes で書く
PLAN_SH="$("$PY" - "$PLAN_JSON" <<'PY'
import json, re, shlex, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
out = []
for k, v in (p.get("env") or {}).items():
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", str(k)):
        print(f"verify.sh: verify.env の名前が不正なので無視: {k!r}", file=sys.stderr)
        continue
    if isinstance(v, bool):
        v = "true" if v else "false"
    out.append(f"export {k}={shlex.quote(str(v))}")
steps = p.get("steps") or []
for key in ("stack", "path", "kind", "cmd"):
    out.append(f"STEP_{key.upper()}=(" + " ".join(shlex.quote(str(s.get(key, ""))) for s in steps) + ")")
sys.stdout.buffer.write(("\n".join(out) + "\n").encode("utf-8"))
PY
)" || { echo "verify.sh: plan.json を読めない" >&2; echo "VERIFY=fail STEPS=0 FAILED=0"; exit 1; }
STEP_STACK=(); STEP_PATH=(); STEP_KIND=(); STEP_CMD=()
eval "$PLAN_SH"

N=${#STEP_CMD[@]}
if [ "$MODE" = all ] || [ "$MODE" = always ]; then
  echo "verify.sh: mode=$MODE steps=$N"
else
  echo "verify.sh: mode=changed files=$(printf '%s\n' "$CHANGED" | grep -c . ) source=${CHANGED_SRC:-git diff $BASE...HEAD + uncommitted} steps=$N"
fi
if [ "$N" -eq 0 ]; then
  echo "verify.sh: 実行する検証なし (変更がどのスタックにも該当しない)" >&2
fi

# ---- 特殊コマンド ---------------------------------------------------------------------------
# pip 経路は隔離 venv (.sweepline/venv、stack の path 直下) を使う。VM の system python に入れると Debian 由来の
# パッケージ (PyJWT / cffi 等) と衝突して uninstall できない (shadowverse_tool の初回 sweep で発生)。
# venv は python_session.sh (python_version の pin 付き) が先に作っていればそれを使い、無ければここで python3 で作る。
PY_INSTALL='if [ -f uv.lock ]; then uv sync --group dev || uv sync;
elif [ -f requirements-ci.txt ] || [ -f requirements.txt ]; then
  VENV=.sweepline/venv; [ -x "$VENV/bin/python" ] || '"$PY"' -m venv "$VENV" || exit 1
  "$VENV/bin/python" -m pip install -q --upgrade pip >/dev/null 2>&1 || true
  REQ=requirements-ci.txt; [ -f "$REQ" ] || REQ=requirements.txt
  "$VENV/bin/python" -m pip install -q -r "$REQ";
else echo "python install: nothing to install (no uv.lock / requirements-ci.txt / requirements.txt)"; fi'
PY_TEST='if [ -d tests ] || [ -d test ] || [ -f pytest.ini ] || [ -f pyproject.toml ]; then
  if [ -f uv.lock ]; then uv run pytest -q; else
    PYX=.sweepline/venv/bin/python; [ -x "$PYX" ] || PYX='"$PY"'
    "$PYX" -m pytest -q; fi; rc=$?
  if [ $rc -eq 5 ]; then echo "no tests (pytest collected 0 items)"; rc=0; fi; exit $rc
else echo "no tests"; fi'

TIMEOUT_PREFIX=()
if [ -n "${SWEEPLINE_VERIFY_TIMEOUT:-}" ]; then
  if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_PREFIX=(timeout "$SWEEPLINE_VERIFY_TIMEOUT")
  else
    echo "verify.sh: 警告: timeout コマンドが無いので SWEEPLINE_VERIFY_TIMEOUT を無視する" >&2
  fi
fi

sanitize() { printf '%s' "$1" | sed -e 's/[^A-Za-z0-9._-]/_/g' -e 's/__*/_/g' -e 's/_$//'; }

# ---- 実行 ---------------------------------------------------------------------------------
FAILED=0
RES_LINES=()
for ((i = 0; i < N; i++)); do
  n=$((i + 1))
  stack="${STEP_STACK[$i]}"; spath="${STEP_PATH[$i]:-.}"; kind="${STEP_KIND[$i]}"; cmd="${STEP_CMD[$i]}"
  log="$LOG_DIR/$n-$(sanitize "$stack")-$(sanitize "$kind").log"
  case "$cmd" in
    __python_install__) run="$PY_INSTALL" ;;
    __python_test__) run="$PY_TEST" ;;
    *) run="$cmd" ;;
  esac
  echo ""
  echo "==> [$n/$N] $stack ($spath) $kind: $cmd"
  start=$SECONDS
  {
    echo "# step $n/$N stack=$stack path=$spath kind=$kind"
    echo "# cmd: $cmd"
  } > "$log"
  ( cd "$ROOT/$spath" && ${TIMEOUT_PREFIX[@]+"${TIMEOUT_PREFIX[@]}"} bash -o pipefail -c "$run" ) < /dev/null 2>&1 | tee -a "$log"
  rc=${PIPESTATUS[0]}
  secs=$((SECONDS - start))
  if [ "$rc" -eq 0 ]; then
    res="OK"
  else
    res="FAIL"; FAILED=$((FAILED + 1))
    if [ "$rc" -eq 124 ] && [ -n "${TIMEOUT_PREFIX[*]+x}" ]; then
      echo "# TIMEOUT: SWEEPLINE_VERIFY_TIMEOUT=$SWEEPLINE_VERIFY_TIMEOUT を超えた" | tee -a "$log"
    fi
  fi
  echo "# exit=$rc seconds=$secs result=$res" >> "$log"
  RES_LINES+=("$(printf '%-4s %-10s %-28s %6s  %-4s %4s  %s' "$n" "$stack" "$kind" "$secs" "$res" "$rc" "$log")")
done

# ---- まとめ -------------------------------------------------------------------------------
VERDICT=ok; [ $FAILED -gt 0 ] && VERDICT=fail
{
  echo ""
  echo "---- verify summary ----"
  printf '%-4s %-10s %-28s %6s  %-4s %4s  %s\n' "step" "stack" "kind" "sec" "res" "rc" "log"
  for l in ${RES_LINES[@]+"${RES_LINES[@]}"}; do echo "$l"; done
  echo "VERIFY=$VERDICT STEPS=$N FAILED=$FAILED"
} | tee "$LOG_DIR/summary.txt"
[ $FAILED -eq 0 ] || exit 1
exit 0
