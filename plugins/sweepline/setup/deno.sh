# =============================================================================
# sweepline: stack deno の setup (Deno CLI)
#
# opts: deno_version (例 "2.1.4"。空なら最新)
# 公式 installer (deno.land/install.sh → dl.deno.land) で SWEEPLINE_ROOT/deno に入れて SWEEPLINE_BIN に
# symlink する。installer が通らなければ GitHub Release の zip にフォールバックする。
# 必要ドメイン: deno.land / dl.deno.land (installer) または github.com (フォールバック)
# =============================================================================
pl_setup_deno() {
  local DENO_VERSION="@@DENO_VERSION@@"
  local DENO_HOME="$SWEEPLINE_ROOT/deno" V="" target url
  [ -n "$DENO_VERSION" ] && V="v${DENO_VERSION#v}"
  if [ -x "$DENO_HOME/bin/deno" ] \
     && { [ -z "$V" ] || "$DENO_HOME/bin/deno" --version 2>/dev/null | head -1 | grep -qF "deno ${V#v} "; }; then
    log "deno: already installed"
  else
    mkdir -p "$DENO_HOME"
    # stdout を log に向けるので installer の対話的 shell setup は走らない (CI=1 でも抑止)
    curl -fsSL https://deno.land/install.sh 2>/dev/null \
      | env CI=1 DENO_INSTALL="$DENO_HOME" sh -s -- ${V:+"$V"} --no-modify-path >>"$PL_LOG" 2>&1
    if [ ! -x "$DENO_HOME/bin/deno" ]; then
      case "$(uname -m)" in aarch64|arm64) target=aarch64-unknown-linux-gnu ;; *) target=x86_64-unknown-linux-gnu ;; esac
      url="https://github.com/denoland/deno/releases/latest/download/deno-$target.zip"
      [ -n "$V" ] && url="https://github.com/denoland/deno/releases/download/$V/deno-$target.zip"
      log "deno: installer FAILED → $url"
      mkdir -p "$DENO_HOME/bin"
      curl -fsSL -o "$DENO_HOME/deno.zip" "$url" && unzip -oq "$DENO_HOME/deno.zip" -d "$DENO_HOME/bin" \
        && chmod +x "$DENO_HOME/bin/deno" || log "deno: GitHub Release download FAILED"
      rm -f "$DENO_HOME/deno.zip"
    fi
  fi
  if [ -x "$DENO_HOME/bin/deno" ]; then
    pl_link "$DENO_HOME/bin/deno" || log "deno: link FAILED"
    pl_env "export DENO_INSTALL=\"$DENO_HOME\"" "export PATH=\"$DENO_HOME/bin:\$PATH\""
    log "deno: $("$DENO_HOME/bin/deno" --version 2>/dev/null | head -1)"
  else
    log "deno: install FAILED (deno.land / dl.deno.land / github.com が許可されているか確認)"
  fi
}
pl_setup_deno
