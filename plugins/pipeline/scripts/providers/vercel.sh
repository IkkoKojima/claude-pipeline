#!/bin/bash
# providers/vercel.sh — Vercel CLI で本番デプロイする (Git 連携で自動デプロイされる project には不要)。
#
# pipeline.toml:
#   [[release.providers]]
#   type = "vercel"
#   dir = "web"                 # vercel deploy を実行するディレクトリ (既定 ".")
#   # project = "my-site"       # 指定時は先に `vercel link --yes --project` する (.vercel/ が無い checkout 用)
#   # scope = "my-team"         # team slug (--scope)
#   # check_url = "https://example.com/"   # status で疎通を見る URL (省略時は確認しない)
#
# 資格: VERCEL_TOKEN (api.vercel.com)。deploy は完了まで待つ同期処理なので、ID はデプロイ URL、status は常に finished
# (check_url があればその疎通で判定)。

PROVIDER_TYPE=vercel
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

v_token() {
  if [[ -n "${VERCEL_TOKEN:-}" ]]; then printf '%s' "$VERCEL_TOKEN"; return 0; fi
  if [[ "${CLAUDE_CODE_REMOTE:-}" == "true" ]]; then printf 'proxy-injected'; return 0; fi
  return 1
}

p_preflight() {
  local dir
  v_token >/dev/null || preflight_ng "VERCEL_TOKEN が無い (secrets_list を参照)"
  dir="$(pget dir .)"
  [[ -d "$dir" ]] || preflight_ng "dir '$dir' が無い"
  command -v npx >/dev/null 2>&1 || preflight_ng "npx が無い (node をインストールする)"
  kv DIR "$dir"
  kv PREFLIGHT ok
}

p_deploy() {
  local version="${1:-}" sha="${2:-}" dir project scope token out url
  local -a scope_args=() args=()
  [[ -n "$version" ]] || die "使い方: deploy <version> <sha>"
  token="$(v_token)" || die "VERCEL_TOKEN が無い"
  dir="$(pget dir .)"
  [[ -d "$dir" ]] || die "dir '$dir' が無い"
  project="$(pget project)"
  scope="$(pget scope)"
  [[ -n "$scope" ]] && scope_args=(--scope "$scope")
  if [[ -n "$project" ]]; then
    ( cd "$dir" && npx --yes vercel link --yes --project "$project" ${scope_args[@]+"${scope_args[@]}"} --token "$token" ) >&2 \
      || die "vercel link に失敗 (project=$project)"
  fi
  args=(deploy --prod --yes --token "$token" --meta "release=$version")
  [[ -n "$sha" ]] && args+=(--meta "sha=$sha")
  out="$(cd "$dir" && npx --yes vercel "${args[@]}" ${scope_args[@]+"${scope_args[@]}"})" || die "vercel deploy に失敗"
  printf '%s\n' "$out" >&2
  url="$(printf '%s\n' "$out" | grep -Eo 'https://[^[:space:]]+' | tail -n1)" || url=""
  [[ -n "$url" ]] || die "vercel deploy の出力にデプロイ URL が無い"
  kv ID "$url"
  kv URL "$url"
  kv STATUS finished
}

p_status() {
  local check
  check="$(pget check_url)"
  if [[ -n "$check" ]]; then
    if url_ok "$check"; then kv STATUS finished; else kv STATUS failed; kv REASON "$check に到達できない"; fi
  else
    kv STATUS finished
  fi
}

p_secrets_list() {
  kv SECRET "VERCEL_TOKEN|env_credential:api.vercel.com|Vercel → Account Settings → Tokens (対象 team のスコープ)。CLI に --token で渡す"
}

p_notes_limits() { emit_limits ""; }

provider_main "$@"
