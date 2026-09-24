#!/bin/bash
# providers/cloudflare-pages.sh — wrangler で Cloudflare Pages に直接アップロードする。
#
# pipeline.toml:
#   [[release.providers]]
#   type = "cloudflare-pages"
#   dir = "web"                 # アップロードするディレクトリ (必須)
#   project = "my-pages"        # Pages の project 名 (必須)
#   # branch = "main"           # 既定 main (= 本番)
#   # account_id = "..."        # 省略時は環境変数 CLOUDFLARE_ACCOUNT_ID
#   # check_url = "https://my-pages.pages.dev/"   # status の疎通確認 (既定 https://<project>.pages.dev/)
#
# 資格: CLOUDFLARE_API_TOKEN (api.cloudflare.com、Bearer、Pages:Edit)。クラウドでは placeholder を proxy が差し替える。
# `wrangler whoami` はスコープ不足で失敗するので疎通確認には使わない (Pages projects API を見る)。

PROVIDER_TYPE=cloudflare-pages
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

cf_account() { pget account_id "${CLOUDFLARE_ACCOUNT_ID:-}"; }
cf_token() {
  if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then printf '%s' "$CLOUDFLARE_API_TOKEN"; return 0; fi
  if [[ "${CLAUDE_CODE_REMOTE:-}" == "true" ]]; then printf 'proxy-injected'; return 0; fi
  return 1
}

p_preflight() {
  local acc token dir project
  acc="$(cf_account)"
  [[ -n "$acc" ]] || preflight_ng "CLOUDFLARE_ACCOUNT_ID が無い (環境変数か pipeline.toml の account_id)"
  token="$(cf_token)" || preflight_ng "CLOUDFLARE_API_TOKEN が無い (secrets_list を参照)"
  dir="$(pget dir)"
  project="$(pget project)"
  [[ -n "$dir" && -n "$project" ]] || preflight_ng "dir と project が必要 (pipeline.toml の [[release.providers]] type=cloudflare-pages)"
  [[ -d "$dir" ]] || preflight_ng "dir '$dir' が無い"
  HTTP_HEADERS=(-H "Authorization: Bearer $token")
  http_call GET "https://api.cloudflare.com/client/v4/accounts/$acc/pages/projects/$project"
  [[ "$HTTP_CODE" == 200 ]] || preflight_ng "Pages project '$project' の取得が HTTP $HTTP_CODE (token のスコープ / account id / project 名を確認)"
  kv PROJECT "$project"
  kv DIR "$dir"
  kv PREFLIGHT ok
}

p_deploy() {
  local version="${1:-}" sha="${2:-}" acc dir project branch out url
  local -a args=()
  [[ -n "$version" ]] || die "使い方: deploy <version> <sha>"
  dir="$(pget dir)"
  project="$(pget project)"
  [[ -n "$dir" && -n "$project" ]] || die "dir と project が必要"
  [[ -d "$dir" ]] || die "dir '$dir' が無い"
  branch="$(pget branch main)"
  acc="$(cf_account)"
  [[ -n "$acc" ]] && export CLOUDFLARE_ACCOUNT_ID="$acc"
  if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
    CLOUDFLARE_API_TOKEN="$(cf_token)" || die "CLOUDFLARE_API_TOKEN が無い"
    export CLOUDFLARE_API_TOKEN
  fi
  args=(pages deploy "$dir" --project-name="$project" --branch="$branch" --commit-message="release v$version" --commit-dirty=true)
  [[ -n "$sha" ]] && args+=(--commit-hash="$sha")
  out="$(npx --yes wrangler "${args[@]}" 2>&1)" || { printf '%s\n' "$out" >&2; die "wrangler pages deploy に失敗"; }
  printf '%s\n' "$out" >&2
  url="$(printf '%s\n' "$out" | grep -Eo 'https://[A-Za-z0-9.-]+\.pages\.dev[^[:space:]]*' | tail -n1)" || url=""
  kv ID "${url:-$project@$branch}"
  [[ -n "$url" ]] && kv URL "$url"
  kv STATUS finished
}

p_status() {
  local check project
  project="$(pget project)"
  check="$(pget check_url "${project:+https://$project.pages.dev/}")"
  if [[ -z "$check" ]]; then kv STATUS finished; return 0; fi
  if url_ok "$check"; then kv STATUS finished; else kv STATUS failed; kv REASON "$check に到達できない"; fi
}

p_secrets_list() {
  kv SECRET "CLOUDFLARE_API_TOKEN|env_credential:api.cloudflare.com|Cloudflare → My Profile → API Tokens (Account: Cloudflare Pages:Edit)。環境変数には placeholder (例 proxy-injected) を置き、proxy が Bearer を差し替える"
  if [[ -z "$(pget account_id)" ]]; then
    kv SECRET "CLOUDFLARE_ACCOUNT_ID|env_var|Cloudflare の account id (秘密ではない。pipeline.toml の account_id に書けば不要)"
  fi
}

p_notes_limits() { emit_limits ""; }

provider_main "$@"
