# =============================================================================
# sweepline: stack python の setup (uv + 任意の Python の pin)
#
# opts: python_version (空なら VM 既定の python3 を使う) / requirements (stacks/python_session.sh が使う)
# 依存 (uv sync / pip install -r) は repo が必要なので stacks/python_session.sh (SessionStart) で入れる。
# apt の共有ライブラリ (例: libportaudio2) は sweepline.toml の env.extra_apt に書く (bootstrap が入れる)。
# 必要ドメイン: astral.sh (uv installer。通らなければ PyPI の uv にフォールバック) /
#   github.com (uv python install が落とす python-build-standalone)
# =============================================================================
pl_setup_python() {
  local PY_VERSION="@@PYTHON_VERSION@@"
  local UV=""
  UV="$(command -v uv 2>/dev/null)"
  if [ -n "$UV" ]; then
    log "uv: $("$UV" --version 2>/dev/null) already present"
  else
    curl -LsSf https://astral.sh/uv/install.sh 2>/dev/null \
      | env UV_INSTALL_DIR="$SWEEPLINE_BIN" UV_NO_MODIFY_PATH=1 sh >>"$PL_LOG" 2>&1
    if [ ! -x "$SWEEPLINE_BIN/uv" ]; then
      log "uv: installer FAILED → pip install uv"
      pip install --quiet --break-system-packages uv >>"$PL_LOG" 2>&1 || pip install --quiet uv >>"$PL_LOG" 2>&1 || true
    fi
    UV="$(command -v uv 2>/dev/null)"; [ -n "$UV" ] || UV="$SWEEPLINE_BIN/uv"
    [ -x "$UV" ] && log "uv: $("$UV" --version 2>/dev/null) installed" || log "uv: install FAILED"
  fi

  if [ -n "$PY_VERSION" ] && [ -x "$UV" ]; then
    "$UV" python install "$PY_VERSION" >>"$PL_LOG" 2>&1 \
      && log "python: $PY_VERSION installed (uv managed)" || log "python: uv python install $PY_VERSION FAILED"
  elif [ -n "$PY_VERSION" ]; then
    log "python: uv が無いので $PY_VERSION は入れない (VM 既定の $(python3 --version 2>&1) を使う)"
  else
    log "python: python_version が空 → VM 既定の $(python3 --version 2>&1) を使う"
  fi

  # pytest の保険 (bootstrap の pip install が失敗していた場合)
  [ -n "${P_BOOT_PIP:-}" ] && wait "$P_BOOT_PIP" 2>/dev/null
  if ! python3 -c 'import pytest' >/dev/null 2>&1; then
    { { [ -x "$UV" ] && "$UV" pip install --system --break-system-packages "pytest>=8.0"; } \
        || pip install --quiet --break-system-packages "pytest>=8.0" || pip install --quiet "pytest>=8.0"; } >>"$PL_LOG" 2>&1 \
      && log "pytest: installed (fallback)" || log "pytest: fallback install FAILED"
  fi
}
pl_setup_python
