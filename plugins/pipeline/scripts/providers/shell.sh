#!/bin/bash
# providers/shell.sh — 任意のコマンド列で配信する (他の provider に当てはまらないもの)。
#
# pipeline.toml:
#   [[release.providers]]
#   type = "shell"
#   commands = ["npm run build", "npx some-cli publish --tag \"v$RELEASE_VERSION\""]   # 順に実行。1 つでも失敗したら止める
#   # dir = "."                     # 実行ディレクトリ (既定 repo ルート)
#   # secrets = ["SOME_TOKEN"]      # コマンドが使う環境変数 (preflight が存在を確認し、secrets_list に出す)
#   # secret_host = "api.example.com"  # secrets の置き場所の案内 (env_credential:<host>)。省略時は env_var
#   # notes_limits = { STORE = 1000 }  # ストア文面の上限があれば
#
# 各コマンドは `bash -c` で実行し、RELEASE_VERSION / RELEASE_SHA を export する。コマンドの出力は stderr に流す
# (stdout は KEY=value 行だけ)。同期処理なので status は常に finished。

PROVIDER_TYPE=shell
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

p_preflight() {
  local dir c n=0 s
  dir="$(pget dir .)"
  [[ -d "$dir" ]] || preflight_ng "dir '$dir' が無い"
  while IFS= read -r -d '' c; do
    [[ -n "$c" ]] || continue
    n=$((n + 1))
    bash -n -c "$c" 2>/dev/null || preflight_ng "commands[$((n - 1))] の構文が不正: $c"
  done < <(pget_list commands)
  (( n > 0 )) || preflight_ng "commands が無い (pipeline.toml の [[release.providers]] type=shell)"
  while IFS= read -r -d '' s; do
    [[ -n "$s" ]] || continue
    [[ "$s" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || preflight_ng "secrets の名前が不正: $s"
    [[ -n "${!s:-}" ]] || preflight_ng "環境変数 $s が無い (secrets_list を参照)"
  done < <(pget_list secrets)
  kv COMMANDS "$n"
  kv PREFLIGHT ok
}

p_deploy() {
  local version="${1:-}" sha="${2:-}" dir c i=0
  local -a cmds=()
  [[ -n "$version" ]] || die "使い方: deploy <version> <sha>"
  dir="$(pget dir .)"
  [[ -d "$dir" ]] || die "dir '$dir' が無い"
  while IFS= read -r -d '' c; do
    if [[ -n "$c" ]]; then cmds+=("$c"); fi
  done < <(pget_list commands)
  (( ${#cmds[@]} > 0 )) || die "commands が無い"
  export RELEASE_VERSION="$version" RELEASE_SHA="$sha"
  for c in "${cmds[@]}"; do
    echo "shell: [$i] $c" >&2
    if ! ( cd "$dir" && bash -c "$c" ) >&2; then
      kv FAILED_STEP "$i"
      kv STATUS failed
      die "commands[$i] が失敗: $c"
    fi
    i=$((i + 1))
  done
  kv ID "shell@$(utc_iso 0)"
  kv STATUS finished
}

p_status() { kv STATUS finished; }

p_secrets_list() {
  local s host where
  host="$(pget secret_host)"
  where="env_var"
  [[ -n "$host" ]] && where="env_credential:$host"
  while IFS= read -r -d '' s; do
    if [[ -n "$s" ]]; then kv SECRET "$s|$where|commands が参照する"; fi
  done < <(pget_list secrets)
}

p_notes_limits() { emit_limits ""; }

provider_main "$@"
