# =============================================================================
# sweepline: stack flutter の setup (Flutter SDK + Android SDK)
#
# opts (sweepline.toml の [[stacks]] に同名キーで書くと上書き。env_api.py render が置換する):
#   flutter_version / android_platform / android_build_tools / android_cmdline_tools (任意、既定 15859902)
#   android_platform を "" にすると Android SDK は入れない (precache も --linux のみ)。
# 5 分に収めるため Flutter tarball と Android SDK を並列に落とし、両方そろってから symlink / precache
# (pokemonitor 実測: 合計約 2 分)。repo 依存の処理 (pub get / native hook キャッシュ復元 / 温め) は
# stacks/flutter_session.sh (SessionStart) で行う。
# 必要ドメイン: storage.googleapis.com (既定リスト) + dl.google.com / maven.google.com (preset hosts)
# =============================================================================
pl_setup_flutter() {
  local FLUTTER_VERSION="@@FLUTTER_VERSION@@"
  local ANDROID_PLATFORM="@@ANDROID_PLATFORM@@"
  local ANDROID_BUILD_TOOLS="@@ANDROID_BUILD_TOOLS@@"
  local CMDLINE_TOOLS_REV="@@ANDROID_CMDLINE_TOOLS@@"
  [ -n "$CMDLINE_TOOLS_REV" ] || CMDLINE_TOOLS_REV=15859902
  local FLUTTER_HOME="$SWEEPLINE_ROOT/flutter" ANDROID_HOME="$SWEEPLINE_ROOT/android-sdk"
  local P_SDK="" P_ANDROID="" exe pre
  if [ -z "$FLUTTER_VERSION" ]; then log "flutter: flutter_version が空 → skip"; return 0; fi
  log "flutter: version=$FLUTTER_VERSION android=${ANDROID_PLATFORM:-none} build-tools=${ANDROID_BUILD_TOOLS:-none}"

  # ---- 1) Flutter SDK (stable tarball 約 1.5 GB。Dart SDK 同梱) ----
  (
    if [ -x "$FLUTTER_HOME/bin/flutter" ] && { grep -qxF "$FLUTTER_VERSION" "$FLUTTER_HOME/version" 2>/dev/null \
         || grep -qs "\"frameworkVersion\": *\"$FLUTTER_VERSION\"" "$FLUTTER_HOME/bin/cache/flutter.version.json"; }; then
      log "flutter: $FLUTTER_VERSION already installed"; exit 0
    fi
    rm -rf "$FLUTTER_HOME"
    URL="https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"
    log "flutter: download+extract $URL"
    curl -fsSL "$URL" | tar -xJ -C "$SWEEPLINE_ROOT" && [ -x "$FLUTTER_HOME/bin/flutter" ] \
      && log "flutter: extracted" || log "flutter: download/extract FAILED"
  ) &
  P_SDK=$!

  # ---- 2) Android SDK (cmdline-tools → platform-tools / platform / build-tools) ----
  if [ -n "$ANDROID_PLATFORM" ]; then
    (
      if [ -d "$ANDROID_HOME/platforms/$ANDROID_PLATFORM" ] \
         && { [ -z "$ANDROID_BUILD_TOOLS" ] || [ -d "$ANDROID_HOME/build-tools/$ANDROID_BUILD_TOOLS" ]; }; then
        log "android: already installed"; exit 0
      fi
      mkdir -p "$ANDROID_HOME/cmdline-tools"
      ZIP="$SWEEPLINE_ROOT/cmdline-tools.zip"
      URL="https://dl.google.com/android/repository/commandlinetools-linux-${CMDLINE_TOOLS_REV}_latest.zip"
      log "android: download $URL"
      if curl -fsSL -o "$ZIP" "$URL"; then
        rm -rf "$ANDROID_HOME/cmdline-tools/latest" "$ANDROID_HOME/cmdline-tools/cmdline-tools"
        unzip -q "$ZIP" -d "$ANDROID_HOME/cmdline-tools" && mv "$ANDROID_HOME/cmdline-tools/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest"
        rm -f "$ZIP"
        SDKM="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
        yes | "$SDKM" --sdk_root="$ANDROID_HOME" --licenses >/dev/null 2>&1 || true
        PKGS="platform-tools platforms;$ANDROID_PLATFORM"
        [ -n "$ANDROID_BUILD_TOOLS" ] && PKGS="$PKGS build-tools;$ANDROID_BUILD_TOOLS"
        # shellcheck disable=SC2086
        "$SDKM" --sdk_root="$ANDROID_HOME" $PKGS >/dev/null 2>&1 \
          && log "android: sdk packages installed ($PKGS)" || log "android: sdkmanager FAILED (dl.google.com が許可されているか確認)"
      else
        log "android: cmdline-tools download FAILED (dl.google.com が許可されているか確認)"
      fi
    ) &
    P_ANDROID=$!
  else
    log "android: android_platform が空 → Android SDK は入れない"
  fi
  wait "$P_SDK" ${P_ANDROID:+"$P_ANDROID"} 2>/dev/null

  # ---- 3) PATH: 非ログインシェルでも見えるよう symlink + env.sh ----
  for exe in flutter dart; do pl_link "$FLUTTER_HOME/bin/$exe"; done   # 実体が無ければ何もしない (DL 失敗は上で記録済み)
  pl_link "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
  pl_link "$ANDROID_HOME/platform-tools/adb"
  pl_env "export FLUTTER_HOME=\"$FLUTTER_HOME\""
  if [ -n "$ANDROID_PLATFORM" ]; then
    pl_env "export ANDROID_HOME=\"$ANDROID_HOME\"" \
           "export ANDROID_SDK_ROOT=\"$ANDROID_HOME\"" \
           "export PATH=\"$FLUTTER_HOME/bin:$ANDROID_HOME/platform-tools:\$PATH\""
  else
    pl_env "export PATH=\"$FLUTTER_HOME/bin:\$PATH\""
  fi

  # ---- 4) Flutter を一度起動してキャッシュを温める (engine artifacts) ----
  if [ -x "$FLUTTER_HOME/bin/flutter" ]; then
    git config --global --add safe.directory "$FLUTTER_HOME" 2>/dev/null || true
    "$FLUTTER_HOME/bin/flutter" config --no-analytics >/dev/null 2>&1 || true
    # ANDROID_HOME が Bash ツールの環境に無くても flutter build apk が SDK を見つけられるようにする
    if [ -n "$ANDROID_PLATFORM" ] && [ -d "$ANDROID_HOME/platforms" ]; then
      "$FLUTTER_HOME/bin/flutter" config --android-sdk "$ANDROID_HOME" >/dev/null 2>&1 || true
    fi
    pre="--linux"; [ -n "$ANDROID_PLATFORM" ] && pre="$pre --android"
    # shellcheck disable=SC2086
    "$FLUTTER_HOME/bin/flutter" precache $pre >/dev/null 2>&1 && log "flutter: precache done ($pre)" || log "flutter: precache FAILED"
    log "flutter: $("$FLUTTER_HOME/bin/flutter" --version 2>/dev/null | head -1)"
  else
    log "flutter: SDK が無いので symlink / precache しない"
  fi
}
pl_setup_flutter
