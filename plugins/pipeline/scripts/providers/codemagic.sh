#!/bin/bash
# providers/codemagic.sh — Codemagic でモバイルをビルドし、Play 内部テスト / TestFlight へ配信する。
#
# pipeline.toml:
#   [[release.providers]]
#   type = "codemagic"
#   workflows = ["android-internal", "ios-testflight"]   # 起動順。CREATE_TAG=true は先頭の workflow だけ
#   app_id = "..."                  # 省略時は環境変数 CODEMAGIC_APP_ID
#   branch = "main"                 # ビルドするブランチ (API にコミット指定が無いので RELEASE_SHA 変数で渡し、workflow 側で照合する)
#   variable_group = "pipeline_release"   # secrets_list の案内に使うグループ名 (既定)
#   # groups = { play_publishing = ["GCLOUD_SERVICE_ACCOUNT_CREDENTIALS"], github_release = ["GITHUB_RELEASE_TOKEN"] }  # 複数グループ
#   # notes_limits = { PLAY = 500, TESTFLIGHT = 4000 }  # 省略時この値
#
# 資格: CODEMAGIC_API_TOKEN (ヘッダ x-auth-token)。クラウドで未設定なら placeholder を送り、環境の API credentials の注入に任せる
# (効くかは preflight の GET /apps で分かる)。
# workflow に渡す変数: RELEASE_VERSION / RELEASE_SHA / CREATE_TAG ("true" の workflow が配信成功後にタグと GitHub Release を作る)。
# deploy の ID は build id のカンマ区切り (workflow 順)。status はそれを受けて全体の状態を返す。

PROVIDER_TYPE=codemagic
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

CM_API="${CODEMAGIC_API_URL:-https://api.codemagic.io}"

cm_token() {
  if [[ -n "${CODEMAGIC_API_TOKEN:-}" ]]; then printf '%s' "$CODEMAGIC_API_TOKEN"; return 0; fi
  if [[ "${CLAUDE_CODE_REMOTE:-}" == "true" ]]; then printf 'proxy-injected'; return 0; fi
  return 1
}
cm_headers() {
  local t
  t="$(cm_token)" || die "CODEMAGIC_API_TOKEN が無い (secrets_list を参照)"
  HTTP_HEADERS=(-H "x-auth-token: $t" -H "Accept: application/json")
}
cm_app() { pget app_id "${CODEMAGIC_APP_ID:-}"; }

# workflow ごとの POST /builds の body
cm_body() {  # app workflow branch version sha create_tag
  "$PY" -c '
import json, sys
app, wf, branch, ver, sha, tag = sys.argv[1:7]
v = {"RELEASE_VERSION": ver, "CREATE_TAG": tag}
if sha:
    v["RELEASE_SHA"] = sha
sys.stdout.buffer.write(json.dumps({"appId": app, "workflowId": wf, "branch": branch,
                                    "environment": {"variables": v}}).encode("utf-8"))
' "$@"
}

# build の status を JSON から (build.status → 無ければ最初の "status":"x")
cm_status_of() {
  local s
  s="$(printf '%s' "$1" | json_get build.status 2>/dev/null)" || s=""
  if [[ -z "$s" ]]; then
    s="$(printf '%s' "$1" | grep -oE '"status"[[:space:]]*:[[:space:]]*"[A-Za-z_]+"' | head -n1 | sed -E 's/.*"([A-Za-z_]+)"$/\1/')" || s=""
  fi
  printf '%s' "$s"
}

p_preflight() {
  local app wfs
  cm_token >/dev/null || preflight_ng "CODEMAGIC_API_TOKEN が無い (secrets_list を参照)"
  app="$(cm_app)"
  [[ -n "$app" ]] || preflight_ng "app_id が無い (pipeline.toml の app_id か環境変数 CODEMAGIC_APP_ID)"
  wfs="$(pget workflows)"
  [[ -n "$wfs" ]] || preflight_ng "workflows が無い (pipeline.toml の [[release.providers]] type=codemagic)"
  cm_headers
  http_call GET "$CM_API/apps/$app"
  [[ "$HTTP_CODE" == 200 ]] || preflight_ng "GET /apps/$app が HTTP $HTTP_CODE (token か app_id を確認): $(short "$HTTP_BODY")"
  kv APP_ID "$app"
  kv WORKFLOWS "$(printf '%s' "$wfs" | tr '\n' ',' | sed 's/,$//')"
  kv PREFLIGHT ok
}

p_deploy() {
  local version="${1:-}" sha="${2:-}" app branch wf body id ids="" tag=true
  local -a wfs=()
  [[ -n "$version" ]] || die "使い方: deploy <version> <sha>"
  app="$(cm_app)"
  [[ -n "$app" ]] || die "app_id が無い (pipeline.toml の app_id か環境変数 CODEMAGIC_APP_ID)"
  while IFS= read -r -d '' wf; do
    [[ -n "$wf" ]] && wfs+=("$wf")
  done < <(pget_list workflows)
  (( ${#wfs[@]} > 0 )) || die "workflows が無い (pipeline.toml の [[release.providers]] type=codemagic)"
  branch="$(pget branch main)"
  cm_headers
  for wf in "${wfs[@]}"; do
    body="$(cm_body "$app" "$wf" "$branch" "$version" "$sha" "$tag")"
    http_call POST "$CM_API/builds" "$body"
    if [[ ! "$HTTP_CODE" =~ ^2 ]]; then
      kv FAILED "$wf"
      [[ -n "$ids" ]] && kv ID "$ids"
      die "workflow $wf の起動に失敗 (HTTP $HTTP_CODE): $(short "$HTTP_BODY")"
    fi
    id="$(printf '%s' "$HTTP_BODY" | json_get buildId)" || id=""
    [[ -n "$id" ]] || die "workflow $wf: 応答に buildId が無い: $(short "$HTTP_BODY")"
    kv BUILD "$wf:$id"
    ids="${ids:+$ids,}$id"
    tag=false
  done
  kv ID "$ids"
  kv STATUS running
}

p_status() {
  local ids="${1:-}" id raw agg="" any_running=0 any_failed=0
  local -a arr=()
  [[ -n "$ids" ]] || die "使い方: status <build id[,build id...]>"
  cm_headers
  IFS=',' read -r -a arr <<< "$ids"
  for id in "${arr[@]}"; do
    [[ -n "$id" ]] || continue
    http_call GET "$CM_API/builds/$id"
    [[ "$HTTP_CODE" == 200 ]] || die "GET /builds/$id が HTTP $HTTP_CODE: $(short "$HTTP_BODY")"
    raw="$(cm_status_of "$HTTP_BODY")"
    kv BUILD_STATUS "$id:${raw:-unknown}"
    case "$raw" in
      finished) ;;
      failed|canceled|cancelled|timeout|skipped) any_failed=1 ;;
      *) any_running=1 ;;
    esac
  done
  if (( any_failed )); then agg=failed; elif (( any_running )); then agg=running; else agg=finished; fi
  kv STATUS "$agg"
}

p_secrets_list() {
  local pairs g vars v group
  kv SECRET "CODEMAGIC_API_TOKEN|env_credential:api.codemagic.io|Codemagic → Teams → (Personal / Team) settings → Codemagic API の token。ヘッダは x-auth-token なので、proxy 注入が効かなければ環境の環境変数 CODEMAGIC_API_TOKEN に直接置く"
  if [[ -z "$(pget app_id)" ]]; then
    kv SECRET "CODEMAGIC_APP_ID|env_var|Codemagic の app id (/pipeline:setup --deploy が POST /apps で作る。pipeline.toml の app_id に書けば不要)"
  fi
  pairs="$(pget_pairs groups)"
  if [[ -n "$pairs" ]]; then
    while IFS=$'\t' read -r g vars; do
      [[ -n "$g" ]] || continue
      while IFS= read -r v; do
        [[ -n "$v" ]] && kv SECRET "$v|codemagic_group:$g|secure にする"
      done < <(printf '%s' "$vars" | "$PY" -c 'import json,sys
v = json.loads(sys.stdin.buffer.read().decode("utf-8") or "[]")
v = v if isinstance(v, list) else [v]
sys.stdout.buffer.write("".join(str(x) + "\n" for x in v).encode("utf-8"))')
    done <<< "$pairs"
    return 0
  fi
  group="$(pget variable_group pipeline_release)"
  kv SECRET "CM_KEYSTORE|codemagic_group:$group|Android upload keystore (base64)。Code signing 画面の keystore 参照を使うなら不要"
  kv SECRET "CM_KEYSTORE_PASSWORD|codemagic_group:$group|keystore のパスワード"
  kv SECRET "CM_KEY_ALIAS|codemagic_group:$group|鍵の alias"
  kv SECRET "CM_KEY_PASSWORD|codemagic_group:$group|鍵のパスワード"
  kv SECRET "GCLOUD_SERVICE_ACCOUNT_CREDENTIALS|codemagic_group:$group|Play Console のサービスアカウント JSON の中身 (内部テストへの upload)"
  kv SECRET "APP_STORE_CONNECT_ISSUER_ID|codemagic_group:$group|App Store Connect API キーの Issuer ID"
  kv SECRET "APP_STORE_CONNECT_KEY_IDENTIFIER|codemagic_group:$group|App Store Connect API キーの Key ID"
  kv SECRET "APP_STORE_CONNECT_PRIVATE_KEY|codemagic_group:$group|App Store Connect API キー (.p8) の中身"
  kv SECRET "CERTIFICATE_PRIVATE_KEY|codemagic_group:$group|配布証明書用の RSA 秘密鍵 PEM (app-store-connect fetch-signing-files --create 用)"
  kv SECRET "GITHUB_RELEASE_TOKEN|codemagic_group:$group|fine-grained PAT (contents:write のみ)。CREATE_TAG=true の workflow が配信成功後にタグと GitHub Release を作る"
}

p_notes_limits() { emit_limits "PLAY=500 TESTFLIGHT=4000"; }

provider_main "$@"
