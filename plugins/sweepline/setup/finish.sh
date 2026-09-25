# =============================================================================
# sweepline: setup script の締め (env_api.py render が最後に連結する)
# =============================================================================
wait   # bootstrap / stack テンプレート / extra_lines が & で走らせた残りを全部待つ
log "background jobs finished"

# セッションが非 root で動く場合に備えて誰でも書けるようにする (flutter は SDK 配下の bin/cache に書く)
chmod -R a+rwX "$SWEEPLINE_ROOT" 2>/dev/null || true

# ログインシェル向け。Bash ツール向けには SWEEPLINE_BIN の symlink、hook 向けには env.sh を直接 source する
if [ -d /etc/profile.d ] && [ -w /etc/profile.d ]; then
  cp "$PL_ENV_FILE" /etc/profile.d/sweepline.sh 2>/dev/null \
    && log "env: $PL_ENV_FILE → /etc/profile.d/sweepline.sh" || log "env: /etc/profile.d copy FAILED"
fi

log "done in $(( $(date +%s) - T0 ))s (5 分 = 300s 以内が条件)"
exit 0
