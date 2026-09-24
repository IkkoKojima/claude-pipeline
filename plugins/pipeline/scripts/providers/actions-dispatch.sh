#!/bin/bash
# providers/actions-dispatch.sh — VM で出来ないビルド / 配信 (Windows MSIX、Mac 署名等) を既存の GitHub Actions workflow に委ねる。
#
# pipeline.toml:
#   [[release.providers]]
#   type = "actions-dispatch"
#   workflow = "release-msix.yml"   # workflow のファイル名か id (必須。on: workflow_dispatch と inputs.version を持つこと)
#   # ref = "main"                  # dispatch する ref (既定 main)
#   # repo = "owner/name"           # 既定はこの repo (セッションに attach された repo でないと REST が通らない)
#   # version_input = "version"     # 版を渡す input 名 (既定 version)
#   # sha_input = "sha"             # 指定時は対象 SHA も渡す
#   # inputs = { channel = "store" }  # 追加の固定 inputs
#   # secrets = ["MSIX_CERT_PFX"]   # workflow が参照する repo secrets (secrets_list の案内用)
#
# dispatch は run id を返さないので、ID は "<workflow>@<dispatch 直前 2 分の UTC 時刻>"。status はその workflow の
# 最新の workflow_dispatch run (REST actions/workflows/<workflow>/runs?per_page=1) を見て、時刻より前の run しか無ければ running。

PROVIDER_TYPE=actions-dispatch
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

ad_repo() {
  local r
  r="$(pget repo)"
  if [[ -z "$r" ]]; then r="$(repo_slug)" || return 1; fi
  printf '%s' "$r"
}

p_preflight() {
  local wf slug state
  wf="$(pget workflow)"
  [[ -n "$wf" ]] || preflight_ng "workflow が無い (pipeline.toml の [[release.providers]] type=actions-dispatch)"
  command -v gh >/dev/null 2>&1 || preflight_ng "gh が無い"
  slug="$(ad_repo)" || preflight_ng "repo (owner/name) が決まらない"
  state="$(ghapi "repos/$slug/actions/workflows/$wf" --jq '.state' 2>/dev/null)" \
    || preflight_ng "repos/$slug/actions/workflows/$wf を取得できない (workflow 名 / repo の attach / gh の認証を確認)"
  [[ "$state" == active ]] || preflight_ng "workflow $wf の state が $state (active でない)"
  kv REPO "$slug"
  kv WORKFLOW "$wf"
  kv PREFLIGHT ok
}

p_deploy() {
  local version="${1:-}" sha="${2:-}" wf slug ref vin sin since k v pairs
  local -a args=()
  [[ -n "$version" ]] || die "使い方: deploy <version> <sha>"
  wf="$(pget workflow)"
  [[ -n "$wf" ]] || die "workflow が無い"
  slug="$(ad_repo)" || die "repo (owner/name) が決まらない"
  ref="$(pget ref main)"
  vin="$(pget version_input version)"
  sin="$(pget sha_input)"
  args=(-X POST "repos/$slug/actions/workflows/$wf/dispatches" -f "ref=$ref" -f "inputs[$vin]=$version")
  if [[ -n "$sin" && -n "$sha" ]]; then args+=(-f "inputs[$sin]=$sha"); fi
  pairs="$(pget_pairs inputs)"
  while IFS=$'\t' read -r k v; do
    if [[ -n "$k" ]]; then args+=(-f "inputs[$k]=$v"); fi
  done <<< "$pairs"
  since="$(utc_iso 2)"
  ghapi "${args[@]}" >/dev/null || die "workflow $wf の dispatch に失敗 (repos/$slug)"
  kv ID "$wf@$since"
  kv DISPATCHED_AT "$since"
  kv STATUS running
}

p_status() {
  local id="${1:-}" wf since="" slug line run_id st concl created url
  [[ -n "$id" ]] || die "使い方: status <workflow@time>"
  wf="${id%@*}"
  if [[ "$id" == *@* ]]; then since="${id##*@}"; fi
  [[ -n "$wf" ]] || wf="$(pget workflow)"
  slug="$(ad_repo)" || die "repo (owner/name) が決まらない"
  line="$(ghapi "repos/$slug/actions/workflows/$wf/runs?per_page=1&event=workflow_dispatch" \
    --jq '.workflow_runs[0] // empty | [(.id | tostring), .status, (.conclusion // ""), .created_at, .html_url] | join("\t")')" \
    || die "repos/$slug/actions/workflows/$wf/runs を取得できない"
  if [[ -z "$line" ]]; then kv STATUS running; kv NOTE "run がまだ無い"; return 0; fi
  IFS=$'\t' read -r run_id st concl created url <<< "$line"
  if [[ -n "$since" && "$created" < "$since" ]]; then
    kv STATUS running
    kv NOTE "dispatch 後の run がまだ現れていない (最新 run $run_id は $created)"
    return 0
  fi
  kv RUN_ID "$run_id"
  kv URL "$url"
  if [[ "$st" != completed ]]; then
    kv STATUS running
  elif [[ "$concl" == success ]]; then
    kv STATUS finished
  else
    kv STATUS failed
    kv REASON "conclusion=$concl"
  fi
}

p_secrets_list() {
  local slug s found=0
  slug="$(ad_repo 2>/dev/null)" || slug="<owner/name>"
  kv SECRET "(gh の認証)|/web-setup|dispatch には actions:write 相当の権限が要る。クラウドは /web-setup で登録した gh トークンを使う"
  while IFS= read -r -d '' s; do
    if [[ -n "$s" ]]; then kv SECRET "$s|github_secret:$slug|repo → Settings → Secrets and variables → Actions (workflow が参照)"; found=1; fi
  done < <(pget_list secrets)
  if (( found == 0 )); then
    kv NOTE "workflow が使う秘密は repo の Actions secrets に置く (pipeline.toml の secrets に列挙すると一覧に出る)"
  fi
}

p_notes_limits() { emit_limits ""; }

provider_main "$@"
