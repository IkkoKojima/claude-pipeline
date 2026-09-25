#!/bin/bash
# =============================================================================
# sweepline: stack flutter の SessionStart 処理 (scripts/session_start.sh から呼ばれる)
# 入力 (環境変数): STACK_NAME / STACK_PATH (repo ルートからの相対) / STACK_OPTS (opts の JSON) /
#   SWEEPLINE_ROOT / SWEEPLINE_KIT / SWEEPLINE_LOG_DIR / SWEEPLINE_REPO (owner/name)
# 処理:
#   1) native hook ビルド成果物のキャッシュ (opts.native_cache_tag。空 = 既定なら skip) を GitHub Release から
#      REST で取得 → SWEEPLINE_ROOT/cache/<tag>/ に展開 → .dart_tool/hooks_runner に復元
#      (全 input.json の out_dir_shared が今の clone 先の .dart_tool/hooks_runner/ 配下のときだけ)
#   2) flutter pub get
#   3) 復元したときだけ opts.warmup_test (既定 test/native_smoke_test.dart。あれば) を同期で 1 回流す
# spike 1 で確定した制約 (pokemonitor docs/pipeline/spike-1-results.md):
#   - `gh release download` はリリース解決に GraphQL を使うため proxy で 403 → REST の asset endpoint で取る
#   - input.json は pretty-print → パスの検査は jq で行う (grep では空白差で一致しない)
#   - hooks_runner は絶対パスが違うと CMake が CMakeCache.txt 不一致で止まる (テストが 1 件も走らない)
#   - 復元後 1 回目は PATH 差分で hook が再実行される (CMake 増分、約 26〜41 秒) → 3) で温める。
#     バックグラウンドにすると最初の flutter test と build/unit_test_assets の書き込みが競合するので同期で。
# キャッシュ tarball の作り方: クラウドと同じ絶対パス (/home/user/<repo>) で flutter test を流した後に
#   `tar -czf <name>.tar.gz -C .dart_tool hooks_runner` し、Release <tag> の asset (.tar.gz) に置く。
#   tag 中の {flutter_version} はインストール済み Flutter の版に置換される
#   (例: native_cache_tag = "cache/dartcv-{flutter_version}-linux-x64")。
# =============================================================================
cd "${STACK_PATH:-.}" || exit 0
ROOT="${SWEEPLINE_ROOT:-/opt/sweepline}"
KIT="${SWEEPLINE_KIT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LOG_DIR="${SWEEPLINE_LOG_DIR:-${TMPDIR:-/tmp}}"
LTAG="flutter-$(printf '%s' "${STACK_PATH:-.}" | tr -c 'A-Za-z0-9' '_')"
say() { echo "[sweepline:flutter] $*"; }
# opt KEY DEFAULT : STACK_OPTS に KEY があればその値 (空文字も有効)、無ければ DEFAULT
opt() { python3 -c 'import json,os,sys; v=json.loads(os.environ.get("STACK_OPTS") or "{}").get(sys.argv[1], sys.argv[2]); print("" if v is None else v)' "$1" "$2" 2>/dev/null || printf '%s\n' "$2"; }
# out_dirs DIR : DIR/*/*/input.json の out_dir_shared を 1 行ずつ
out_dirs() {
  if command -v jq >/dev/null 2>&1; then
    jq -r '.out_dir_shared // empty' "$1"/*/*/input.json 2>/dev/null
  else
    python3 -c 'import json,sys; [print(json.load(open(f)).get("out_dir_shared") or "") for f in sys.argv[1:]]' "$1"/*/*/input.json 2>/dev/null
  fi
}

if ! command -v flutter >/dev/null 2>&1; then
  say "WARN: flutter が PATH に無い (環境の setup script 未実行?)"; exit 0
fi
FLUTTER_LINE="$(flutter --version 2>/dev/null | head -1)"
FLUTTER_VER="$(printf '%s\n' "$FLUTTER_LINE" | awk '{print $2}')"
say "${FLUTTER_LINE:-flutter --version failed}"

# ---- 1) native hook キャッシュ ----------------------------------------------------------------
RESTORED=0
TAG="$(opt native_cache_tag "")"
TAG="${TAG//\{flutter_version\}/${FLUTTER_VER:-$(opt flutter_version unknown)}}"
if [ -n "$TAG" ]; then
  CACHE_DIR="$ROOT/cache/$TAG"
  if [ ! -d "$CACHE_DIR/hooks_runner" ]; then
    mkdir -p "$CACHE_DIR"
    ARCHIVE="$CACHE_DIR/archive.tar.gz"
    REPO="${SWEEPLINE_REPO:-$(python3 "$KIT/scripts/sweepline_config.py" repo 2>/dev/null)}"
    if [ ! -s "$ARCHIVE" ] && [ -n "$REPO" ] && command -v gh >/dev/null 2>&1; then
      export GH_TOKEN="${GH_TOKEN:-proxy-injected}"   # 実際の Authorization は proxy が付ける
      ASSET_ID="$(gh api "repos/$REPO/releases/tags/$TAG" --jq '.assets[] | select(.name | endswith(".tar.gz")) | .id' 2>/dev/null | head -1)"
      if [ -n "$ASSET_ID" ] && gh api -H "Accept: application/octet-stream" "repos/$REPO/releases/assets/$ASSET_ID" > "$ARCHIVE.part" 2>/dev/null \
         && [ -s "$ARCHIVE.part" ]; then
        mv "$ARCHIVE.part" "$ARCHIVE"
      else
        rm -f "$ARCHIVE.part"
      fi
    fi
    if [ -s "$ARCHIVE" ]; then
      TMP="$(mktemp -d "$CACHE_DIR/extract.XXXXXX")"
      if tar -xzf "$ARCHIVE" -C "$TMP" 2>/dev/null && [ -d "$TMP/hooks_runner" ]; then
        mv "$TMP/hooks_runner" "$CACHE_DIR/hooks_runner" && rm -f "$ARCHIVE"
      else
        say "WARN: cache archive が壊れている ($ARCHIVE) → 捨てる"; rm -f "$ARCHIVE"
      fi
      rm -rf "$TMP"
    fi
  fi

  if [ -d "$CACHE_DIR/hooks_runner" ] && [ ! -d .dart_tool/hooks_runner ]; then
    # 可搬性ガード: hooks_runner は input.json の絶対パスが一致するときだけ再利用でき、不一致だと
    # CMake が止まってテストが一切走らなくなる → 1 つでも外れていれば復元しない
    WANT="$(pwd)/.dart_tool/hooks_runner/"
    HAVE="$(out_dirs "$CACHE_DIR/hooks_runner")"
    BAD="$(printf '%s\n' "$HAVE" | while IFS= read -r d; do [ -z "$d" ] && continue; case "$d" in "$WANT"*) ;; *) echo "$d" ;; esac; done | head -1)"
    if [ -z "$HAVE" ]; then
      say "native cache: input.json から out_dir_shared を読めない → 復元しない (ソースビルドに任せる)"
    elif [ -n "$BAD" ]; then
      say "native cache: path mismatch (cache=$BAD cwd=$(pwd)) → 復元しない (ソースビルドに任せる)"
    else
      mkdir -p .dart_tool && cp -a "$CACHE_DIR/hooks_runner" .dart_tool/ \
        && { RESTORED=1; say "native cache restored ($TAG)"; } || say "WARN: native cache のコピーに失敗"
    fi
  elif [ ! -d .dart_tool/hooks_runner ]; then
    say "native cache: none (Release $TAG が無い / 取れない。native assets はこのセッションでソースビルドされる)"
  fi
fi

# ---- 2) 依存解決 --------------------------------------------------------------------------------
if flutter pub get > "$LOG_DIR/$LTAG-pub-get.log" 2>&1; then
  say "flutter pub get: ok"
else
  say "WARN: flutter pub get failed (log: $LOG_DIR/$LTAG-pub-get.log)"
fi

# ---- 3) 温め (復元直後の 1 回目は hook が再実行されるので、ここで同期に 1 回流しておく) --------------
if [ "$RESTORED" = 1 ]; then
  WARM="$(opt warmup_test test/native_smoke_test.dart)"
  if [ -n "$WARM" ] && [ -e "$WARM" ]; then
    T0=$(date +%s)
    if timeout 600 flutter test "$WARM" > "$LOG_DIR/$LTAG-warm.log" 2>&1; then
      say "native hook warmed with $WARM ($(( $(date +%s) - T0 ))s)"
    else
      say "WARN: warm-up の flutter test が失敗 (log: $LOG_DIR/$LTAG-warm.log)。作業は通常どおり続行"
    fi
  fi
fi
exit 0
