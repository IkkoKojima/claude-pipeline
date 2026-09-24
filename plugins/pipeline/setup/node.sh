# =============================================================================
# claude-pipeline: stack node の setup (任意の Node / npm の pin)
#
# opts: node_version (例 "20" / "20.18" / "20.18.1"。空なら VM 既定の node 22 を使う)
#       npm_version  (空なら触らない)
# node は nodejs.org の公式 tarball を PIPELINE_ROOT/node に展開し PIPELINE_BIN に symlink する
# ("20" のような系列指定は dist/index.json でその系列の最新に解決)。
# 依存 (npm ci) は repo が必要なので stacks/node_session.sh (SessionStart) で入れる。
# 必要ドメイン: nodejs.org (pin するときだけ)
# =============================================================================
pl_setup_node() {
  local NODE_VERSION="@@NODE_VERSION@@" NPM_VERSION="@@NPM_VERSION@@"
  local NODE_HOME="$PIPELINE_ROOT/node" NPM="npm" arch cur full="" tmp exe
  if [ -z "$NODE_VERSION" ] && [ -z "$NPM_VERSION" ]; then
    log "node: pin なし → VM 既定の node $(node --version 2>/dev/null || echo '?') / npm $(npm --version 2>/dev/null || echo '?') を使う"
    return 0
  fi

  if [ -n "$NODE_VERSION" ]; then
    NODE_VERSION="${NODE_VERSION#v}"
    case "$(uname -m)" in x86_64|amd64) arch=x64 ;; aarch64|arm64) arch=arm64 ;; *) arch="$(uname -m)" ;; esac
    cur="$("$NODE_HOME/bin/node" --version 2>/dev/null)"
    case "$cur" in
      "v$NODE_VERSION"|"v$NODE_VERSION".*)
        log "node: $cur already installed" ;;
      *)
        case "$NODE_VERSION" in
          *.*.*) full="$NODE_VERSION" ;;
          *) full="$(curl -fsSL https://nodejs.org/dist/index.json 2>/dev/null \
               | python3 -c 'import json,sys; p="v"+sys.argv[1]+"."; print(next((r["version"][1:] for r in json.load(sys.stdin) if r["version"].startswith(p)), ""))' "$NODE_VERSION" 2>/dev/null)" ;;
        esac
        tmp="$PIPELINE_ROOT/node.tmp"
        rm -rf "$tmp"; mkdir -p "$tmp"
        if [ -n "$full" ] && curl -fsSL "https://nodejs.org/dist/v$full/node-v$full-linux-$arch.tar.xz" | tar -xJ -C "$tmp" --strip-components=1 \
           && [ -x "$tmp/bin/node" ]; then
          rm -rf "$NODE_HOME" && mv "$tmp" "$NODE_HOME" && log "node: v$full installed" || log "node: swap FAILED"
        else
          rm -rf "$tmp"; log "node: v${full:-$NODE_VERSION} download FAILED (nodejs.org が許可されているか確認)"
        fi ;;
    esac
    # bootstrap の npm install -g (codex) が VM 既定の node で終わってから差し替える
    [ -n "${P_BOOT_NPM:-}" ] && wait "$P_BOOT_NPM" 2>/dev/null
    if [ -x "$NODE_HOME/bin/node" ]; then
      for exe in node npm npx corepack; do pl_link "$NODE_HOME/bin/$exe"; done
      pl_env "export PATH=\"$NODE_HOME/bin:\$PATH\""
      NPM="$NODE_HOME/bin/npm"
    fi
  fi

  if [ -n "$NPM_VERSION" ]; then
    [ -n "${P_BOOT_NPM:-}" ] && wait "$P_BOOT_NPM" 2>/dev/null
    "$NPM" install -g "npm@${NPM_VERSION}" >/dev/null 2>&1 \
      && log "npm: $("$NPM" --version 2>/dev/null) ($NPM)" || log "npm: install npm@$NPM_VERSION FAILED"
  fi
}
pl_setup_node
