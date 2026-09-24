# =============================================================================
# claude-pipeline: 環境 setup script の共通部 (bootstrap)
#
# env_api.py render が次の順に連結して、クラウド環境の init_script (Setup script) にする:
#   ヘッダ (set -u / KIT_REPO / KIT_SHA / PIPELINE_ROOT / EXTRA_APT を export)
#   → この bootstrap.sh → setup/<stack>.sh (opts の placeholder 置換済み) → env.extra_lines → setup/finish.sh
# 単体では実行しない。
#
# 実行条件 (pokemonitor docs/pipeline/spike-2-plugin.md §1 §4):
#   root / Ubuntu 24.04 / repo は **まだ clone されていない** / 環境設定の vars は **未設定** /
#   合計 5 分以内 / 成果はファイルシステムのスナップショットとしてセッションに引き継がれる
#   (~/.claude の marketplace・plugin 登録も含む)。gh は未導入 (apt で入れる)、claude は
#   /opt/node22/bin/claude、node 22 + python 3.11 はある。codeload.github.com は公開 repo なら到達可。
#
# テンプレート共通の規約:
#   - shebang / set -e を書かない。exit しない (最後の finish.sh だけが exit 0 する)。
#   - 失敗は `|| log "... FAILED"` で記録して続行する。ヘッダに set -u があるので、未定義の
#     可能性がある変数は必ず ${VAR:-} で参照する (未定義参照は setup 全体を非 0 で落とす)。
#   - ここで定義する log / pl_link / pl_env / PIPELINE_BIN / PL_ENV_FILE / PL_LOG / P_BOOT_* を使ってよい。
#   - 重い DL は `( ... ) &` で並列にし、依存するものだけ wait する。残りは finish.sh が wait する。
#   - apt-get を使うのはここ (P_BOOT_APT) だけ。stack 側の apt 依存は pipeline.toml の env.extra_apt に書く。
# =============================================================================
T0=$(date +%s)
export DEBIAN_FRONTEND=noninteractive
CODEX_VERSION="${CODEX_VERSION:-0.153.4}"

# root で書けなければ (セッション内で手動実行する検証用) $HOME 配下に落とす
PIPELINE_ROOT="${PIPELINE_ROOT:-/opt/pipeline}"
if ! mkdir -p "$PIPELINE_ROOT" 2>/dev/null || [ ! -w "$PIPELINE_ROOT" ]; then
  PIPELINE_ROOT="${HOME:-/root}/pipeline"; mkdir -p "$PIPELINE_ROOT" 2>/dev/null || true
fi
export PIPELINE_ROOT
PL_LOG="$PIPELINE_ROOT/setup.log"
log() { echo "[pipeline-setup +$(( $(date +%s) - T0 ))s] $*" | tee -a "$PL_LOG"; }

# 非ログインシェル (Bash ツール) からも見えるよう、各ツールは PIPELINE_BIN に symlink する
PIPELINE_BIN=/usr/local/bin
if [ ! -w "$PIPELINE_BIN" ]; then PIPELINE_BIN="${HOME:-/root}/.local/bin"; mkdir -p "$PIPELINE_BIN" 2>/dev/null || true; fi
# pl_link <実体> [名前] : PIPELINE_BIN/<名前> -> <実体> (実体が無ければ何もせず 1 を返す)
pl_link() { [ -e "$1" ] && ln -sfn "$1" "$PIPELINE_BIN/${2:-$(basename "$1")}" 2>/dev/null; }
# pl_env <行>... : env.sh に行を足す (SessionStart hook と /etc/profile.d/pipeline.sh が読む)
PL_ENV_FILE="$PIPELINE_ROOT/env.sh"
pl_env() { printf '%s\n' "$@" >> "$PL_ENV_FILE"; }

log "start: root=$PIPELINE_ROOT kit=${KIT_REPO:-?}@${KIT_SHA:-?} user=$(id -un) extra_apt='${EXTRA_APT:-}'"

# env.sh は毎回作り直す (stack テンプレートが後ろに追記する)
{
  echo "# claude-pipeline: 環境の setup script が生成 ($(date -u +%FT%TZ))。手で編集しない"
  echo "export PIPELINE_ROOT=\"$PIPELINE_ROOT\""
  echo "export PATH=\"$PIPELINE_BIN:\$PATH\""
} > "$PL_ENV_FILE"

# ---- 1) kit (このプラグインの marketplace) を pinned tarball から入れて plugin install -------------
# repo の .claude/settings.json (enabledPlugins) はクラウドで読まれず、セッション中の install は同一
# セッションで効かない (spike 2 §3) → setup で入れて ~/.claude ごとスナップショットに焼く (§4)。
(
  KIT_DIR="$PIPELINE_ROOT/kit"
  REF="${KIT_SHA:-}"
  if [ -z "$REF" ]; then REF=main; log "kit: KIT_SHA が空 → $REF を使う (pin されない)"; fi
  if [ -n "${KIT_SHA:-}" ] && [ "$(cat "$KIT_DIR/.sha" 2>/dev/null)" = "$KIT_SHA" ] && [ -f "$KIT_DIR/.claude-plugin/marketplace.json" ]; then
    log "kit: $REF already extracted"
  else
    TGZ="$PIPELINE_ROOT/kit.tgz"; NEW="$KIT_DIR.new"
    rm -rf "$NEW"; mkdir -p "$NEW"
    if curl -fsSL -o "$TGZ" "https://codeload.github.com/${KIT_REPO:-IkkoKojima/claude-pipeline}/tar.gz/$REF" \
       && tar -xzf "$TGZ" -C "$NEW" --strip-components=1 && [ -f "$NEW/.claude-plugin/marketplace.json" ]; then
      rm -rf "$KIT_DIR" && mv "$NEW" "$KIT_DIR" && printf '%s\n' "$REF" > "$KIT_DIR/.sha" \
        && log "kit: extracted ${KIT_REPO:-?}@$REF" || log "kit: swap FAILED"
    else
      rm -rf "$NEW"; log "kit: download/extract FAILED (${KIT_REPO:-?}@$REF。公開 repo か / codeload.github.com に届くか確認)"
    fi
    rm -f "$TGZ"
  fi
  CLAUDE_BIN="$(command -v claude 2>/dev/null || echo /opt/node22/bin/claude)"
  if [ -f "$KIT_DIR/.claude-plugin/marketplace.json" ] && [ -x "$CLAUDE_BIN" ]; then
    MKT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$KIT_DIR/.claude-plugin/marketplace.json" 2>/dev/null)"
    MKT="${MKT:-claude-pipeline}"
    # marketplace add は登録済みだと失敗する → update に倒す。claude が固まっても 5 分を食わないよう timeout
    { timeout 120 "$CLAUDE_BIN" plugin marketplace add "$KIT_DIR" || timeout 120 "$CLAUDE_BIN" plugin marketplace update "$MKT"; } >>"$PL_LOG" 2>&1 \
      || log "kit: marketplace add/update FAILED ($MKT)"
    if grep -qs "\"pipeline@$MKT\"" "${HOME:-/root}/.claude/plugins/installed_plugins.json"; then
      log "kit: plugin pipeline@$MKT already installed"
    else
      timeout 120 "$CLAUDE_BIN" plugin install "pipeline@$MKT" >>"$PL_LOG" 2>&1 \
        && log "kit: plugin pipeline@$MKT installed" || log "kit: plugin install FAILED (pipeline@$MKT via $CLAUDE_BIN)"
    fi
  else
    log "kit: plugin install skipped (kit か claude が無い: $CLAUDE_BIN)"
  fi
) &
P_BOOT_KIT=$!

# ---- 2) apt: gh (VM に未導入。spike 2 §1) + env.extra_apt ------------------------------------------
(
  if ! command -v gh >/dev/null 2>&1 || [ -n "${EXTRA_APT:-}" ]; then
    apt-get update -qq >/dev/null 2>&1 || log "apt: update FAILED"
  fi
  if command -v gh >/dev/null 2>&1; then
    log "apt: gh already present"
  else
    apt-get install -y -qq gh >/dev/null 2>&1 \
      && log "apt: gh $(gh --version 2>/dev/null | head -1 | awk '{print $3}') installed" || log "apt: gh install FAILED"
  fi
  if [ -n "${EXTRA_APT:-}" ]; then
    # 空白区切りのパッケージ列をそのまま展開する (gh とは別呼び出し: 1 つ誤記しても gh は入る)
    # shellcheck disable=SC2086
    apt-get install -y -qq ${EXTRA_APT} >/dev/null 2>&1 \
      && log "apt: extra installed ($EXTRA_APT)" || log "apt: extra install FAILED ($EXTRA_APT)"
  fi
) &
P_BOOT_APT=$!

# ---- 3) Codex CLI (pin。計画レビュー / コードレビューに使う) -----------------------------------------
(
  npm install -g "@openai/codex@${CODEX_VERSION}" >/dev/null 2>&1 \
    && log "codex: $(codex --version 2>/dev/null)" || log "codex: npm install FAILED"
) &
P_BOOT_NPM=$!

# ---- 4) pytest (パイプライン自身の検証スクリプト用。repo の依存は SessionStart で入れる) -------------
(
  (pip install --quiet --break-system-packages "pytest>=8.0" 2>/dev/null || pip install --quiet "pytest>=8.0" 2>/dev/null) \
    && log "pytest: installed" || log "pytest: install FAILED"
) &
P_BOOT_PIP=$!
