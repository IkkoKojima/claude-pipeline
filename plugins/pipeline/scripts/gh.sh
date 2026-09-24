#!/bin/bash
# gh.sh — pipeline プラグインの GitHub REST ヘルパ。
#
# クラウドセッションでは `gh pr|issue|release` (GraphQL) が 403 になるため、REST の `gh api repos/...` だけを使う
# (到達できるのはセッションに attach された repo のみ)。Windows の Git Bash では `gh api` に MSYS_NO_PATHCONV=1 が要る
# (`repos/...` のパス変換を止める) ので、gh の呼び出しにだけ付ける (python / curl のパスは変換が必要なため全体には付けない)。
# repo・ラベル名・status issue は pipeline.toml (scripts/pipeline_config.py) から読む。ラベル名を直書きしない。
#
# 使い方 (repo ルートで。PIPELINE_ROOT で repo ルート、PIPELINE_REPO で owner/name を上書きできる):
#   gh.sh repo                           owner/name
#   gh.sh api <args...>                  gh api への素通し (MSYS_NO_PATHCONV=1。ファイルは `-F body=@-` と標準入力で渡す)
#   gh.sh label-name <key>               設定のラベル名 (key = ready / in_progress / merged_unverified / blocked / skipped / release)
#   gh.sh ensure-labels                  設定のラベルを無ければ作る (冪等)。EXISTS=<name> / CREATED=<name>
#   gh.sh status-issue                   固定 issue の番号 (status_issue > タイトル前方一致の open issue > 新規作成)
#   gh.sh issue-get N                    {"number","title","state","labels":[...],"body"} (本文は untrusted data)
#   gh.sh issue-labels N                 ラベル名 (1 行 1 件)
#   gh.sh label-add N <label>            ADDED=<label>
#   gh.sh label-del N <label>            REMOVED=<label> / ABSENT=<label> (404 は無視)
#   gh.sh comment N <file|->             COMMENT_ID=<id> / URL=<url>
#   gh.sh issues-ready                   ready 付きで in_progress / blocked / merged_unverified / skipped の無い open issue (古い順、番号のみ)
#   gh.sh issues-in-progress             in_progress 付きの open issue (古い順、番号のみ)
#   gh.sh last-labeled N <label>         そのラベルが最後に付いた時刻 (ISO 8601)。付いたことが無ければ何も出さない (exit 0)
#   gh.sh pr-open-release                head ブランチが release/ で始まる open PR の番号
#   gh.sh issue-create --title T --body-file F [--label L ...]   作成した issue の番号 (F に - を渡すと標準入力)
#   gh.sh comment-find N <prefix>        本文が prefix で始まるコメントの件数
#
# <label> は実名か `@<key>` (例 `@in_progress` → 設定の名前) で渡す。skill からは `@<key>` を使う。
# 失敗時は stderr に理由を出して exit 1 (使い方の誤りは exit 2)。stdout は機械可読な行だけ。

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(dirname "$HERE")"
export PYTHONIOENCODING=utf-8

PY="${PIPELINE_PYTHON:-}"
if [[ -z "$PY" ]]; then
  if command -v python3 >/dev/null 2>&1; then PY=python3; else PY=python; fi
fi

die()   { echo "gh.sh: $*" >&2; exit 1; }
usage() {
  echo "gh.sh: $*" >&2
  echo "使い方: gh.sh {repo|api|label-name|ensure-labels|status-issue|issue-get|issue-labels|label-add|label-del|comment|issues-ready|issues-in-progress|last-labeled|pr-open-release|issue-create|comment-find} ... (詳細はスクリプト冒頭)" >&2
  exit 2
}

# pipeline_config.py (Windows の python は CRLF を出すので \r を落とす)
cfg() { "$PY" "$HERE/pipeline_config.py" ${PIPELINE_ROOT:+--root "$PIPELINE_ROOT"} "$@" | tr -d '\r'; }
_gh() { MSYS_NO_PATHCONV=1 gh "$@"; }

# jq の文字列リテラル (JSON 文字列。ensure_ascii なので \( の注入は起きない)
jqstr() { printf '%s' "$1" | "$PY" -c 'import json,sys; sys.stdout.write(json.dumps(sys.stdin.buffer.read().decode("utf-8")))'; }

# URL のパス / クエリ用エンコード (非予約文字以外を %xx に)
urlenc() {
  local b ch out=""
  for b in $(printf '%s' "$1" | od -An -v -tx1); do
    case "$b" in
      3[0-9]|4[1-9a-f]|5[0-9a]|6[1-9a-f]|7[0-9a]|2d|2e|5f|7e) printf -v ch "\\x$b"; out+="$ch" ;;
      *) out+="%$b" ;;
    esac
  done
  printf '%s' "$out"
}

need_num() { [[ "${1:-}" =~ ^[0-9]+$ ]] || usage "issue 番号が不正: '${1:-}'"; }

# ---------------------------------------------------------------------------------------------
repo_slug() {
  local s="${PIPELINE_REPO:-}" url
  if [[ -z "$s" ]]; then s="$(cfg repo 2>/dev/null)" || s=""; fi
  if [[ -z "$s" ]]; then
    # クラウドセッションの origin は proxy 経由の URL (…/git/OWNER/REPO) のことがあるので末尾 2 要素で拾う
    url="$(git config --get remote.origin.url 2>/dev/null || true)"
    s="$(printf '%s' "$url" | sed -nE 's#^.*[/:]([^/:]+)/([^/]+)$#\1/\2#p' | sed -E 's/\.git$//; s#/$##')"
  fi
  [[ "$s" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "repo (owner/name) が決まらない。pipeline.toml に repo = \"owner/name\" を書くか PIPELINE_REPO を設定する"
  printf '%s\n' "$s"
}
repo_path() { printf 'repos/%s' "$(repo_slug)"; }

# ラベル: key<TAB>name の行。load_labels は L_<key> 変数に展開する
labels_tsv() {
  cfg labels | "$PY" -c 'import json,sys
d = json.loads(sys.stdin.buffer.read().decode("utf-8"))
sys.stdout.buffer.write("".join("%s\t%s\n" % (k, v) for k, v in d.items()).encode("utf-8"))'
}
LABELS_TSV=""
load_labels() {
  local k v
  [[ -n "$LABELS_TSV" ]] && return 0
  LABELS_TSV="$(labels_tsv)" || die "ラベル設定を読めない (pipeline_config.py labels)"
  while IFS=$'\t' read -r k v; do
    [[ "$k" =~ ^[a-z_]+$ && -n "$v" ]] || continue
    printf -v "L_$k" '%s' "$v"
  done <<< "$LABELS_TSV"
  [[ -n "${L_ready:-}" ]] || die "labels.ready が設定に無い"
}
label_of_key() {
  local key="$1" var
  [[ "$key" =~ ^[a-z_]+$ ]] || usage "ラベルキーが不正: '$key'"
  load_labels
  var="L_$key"
  [[ -n "${!var:-}" ]] || die "ラベルキー '$key' は設定に無い (pipeline_config.py labels)"
  printf '%s' "${!var}"
}
label_arg() {
  local a="${1:-}"
  [[ -n "$a" ]] || usage "ラベルが空"
  if [[ "$a" == @* ]]; then label_of_key "${a#@}"; else printf '%s' "$a"; fi
}

render_template() {  # file → {repo} / {status_issue_title} を置換して stdout へ
  local f="$1" body slug title
  body="$(cat "$f")"
  slug="$(repo_slug)"
  title="$(cfg get status_issue_title --default '#pipeline-status')"
  body="${body//\{repo\}/"$slug"}"
  body="${body//\{status_issue_title\}/"$title"}"
  printf '%s\n' "$body"
}

# ---------------------------------------------------------------------------------------------
cmd_ensure_labels() {
  local R existing k name color desc err
  load_labels
  R="$(repo_path)"
  existing="$(_gh api --paginate "$R/labels?per_page=100" --jq '.[].name')"
  while IFS=$'\t' read -r k name; do
    [[ -n "$name" ]] || continue
    if printf '%s\n' "$existing" | grep -Fxiq -- "$name"; then echo "EXISTS=$name"; continue; fi
    case "$k" in
      ready)             color=0E8A16; desc="自動実装パイプライン: 次の sweep が着手してよい" ;;
      in_progress)       color=FBCA04; desc="自動実装パイプライン: セッションが処理中 (6 時間無反応なら sweep が回収)" ;;
      merged_unverified) color=1D76DB; desc="マージ済み・実機確認待ち (リリースのチェックリストに載る)" ;;
      blocked)           color=B60205; desc="自動では進めない。owner の判断・作業が必要 (理由はコメント)" ;;
      skipped)           color=BFBFBF; desc="sweep の対象外 (手動で扱う)" ;;
      release)           color=5319E7; desc="リリース issue ([release] v<version>)" ;;
      *)                 color=EDEDED; desc="自動実装パイプライン ($k)" ;;
    esac
    if err="$(_gh api -X POST "$R/labels" -f name="$name" -f color="$color" -f description="$desc" 2>&1 >/dev/null)"; then
      echo "CREATED=$name"
    else
      case "$err" in
        *already_exists*) echo "EXISTS=$name" ;;
        *) echo "$err" >&2; die "ラベル '$name' を作れない" ;;
      esac
    fi
  done <<< "$LABELS_TSV"
}

cmd_status_issue() {
  local n title R lit found tpl body
  n="$(cfg get status_issue --default 0)"
  if [[ "$n" =~ ^[0-9]+$ ]] && (( 10#$n > 0 )); then echo "$((10#$n))"; return 0; fi
  title="$(cfg get status_issue_title --default '#pipeline-status')"
  [[ -n "$title" ]] || die "status_issue_title が空"
  R="$(repo_path)"
  lit="$(jqstr "$title")"
  found="$(_gh api --paginate "$R/issues?state=open&per_page=100&sort=created&direction=asc" \
    --jq ".[] | select(.pull_request | not) | select(.title | startswith($lit)) | .number")"
  if [[ -n "$found" ]]; then echo "${found%%$'\n'*}"; return 0; fi
  tpl="$PLUGIN_ROOT/templates/status-issue-body.md"
  if [[ -f "$tpl" ]]; then
    body="$(render_template "$tpl")"
  else
    body="自動実装パイプラインの sweep の要約をここにコメントで集める。close しない。"
  fi
  printf '%s\n' "$body" | _gh api -X POST "$R/issues" -f title="$title" -F body=@- --jq '.number'
}

cmd_issue_get() {
  need_num "${1:-}"
  _gh api "$(repo_path)/issues/$1" --jq '{number, title, state, labels: [.labels[].name], body}'
}

cmd_issue_labels() {
  need_num "${1:-}"
  _gh api --paginate "$(repo_path)/issues/$1/labels?per_page=100" --jq '.[].name'
}

cmd_label_add() {
  need_num "${1:-}"
  local L
  L="$(label_arg "${2:-}")"
  _gh api -X POST "$(repo_path)/issues/$1/labels" -f "labels[]=$L" >/dev/null
  echo "ADDED=$L"
}

cmd_label_del() {
  need_num "${1:-}"
  local L err
  L="$(label_arg "${2:-}")"
  if err="$(_gh api -X DELETE "$(repo_path)/issues/$1/labels/$(urlenc "$L")" 2>&1 >/dev/null)"; then
    echo "REMOVED=$L"
  else
    case "$err" in
      *"HTTP 404"*|*"Label does not exist"*) echo "ABSENT=$L" ;;
      *) echo "$err" >&2; die "ラベル '$L' を外せない (#$1)" ;;
    esac
  fi
}

cmd_comment() {
  need_num "${1:-}"
  local src="${2:-}" R q
  [[ -n "$src" ]] || usage "comment N <file|->"
  R="$(repo_path)"
  q='"COMMENT_ID=" + (.id | tostring), "URL=" + .html_url'
  if [[ "$src" == "-" ]]; then
    _gh api -X POST "$R/issues/$1/comments" -F body=@- --jq "$q"
  else
    [[ -f "$src" ]] || die "ファイルが無い: $src"
    _gh api -X POST "$R/issues/$1/comments" -F body=@- --jq "$q" < "$src"
  fi
}

# open issue を「番号<TAB>ラベル…」で列挙 (label で絞る)
_issues_with_label() {
  _gh api --paginate "$(repo_path)/issues?state=open&labels=$(urlenc "$1")&per_page=100&sort=created&direction=asc" \
    --jq '.[] | select(.pull_request | not) | ([(.number | tostring)] + [.labels[].name]) | join("\t")'
}

cmd_issues_ready() {
  local lines line i skip x
  local -a parts excl
  load_labels
  excl=("${L_in_progress:-}" "${L_blocked:-}" "${L_merged_unverified:-}" "${L_skipped:-}")
  lines="$(_issues_with_label "$L_ready")"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    IFS=$'\t' read -r -a parts <<< "$line"
    skip=0
    for (( i = 1; i < ${#parts[@]}; i++ )); do
      for x in "${excl[@]}"; do
        if [[ -n "$x" && "${parts[i]}" == "$x" ]]; then skip=1; fi
      done
    done
    if (( skip == 0 )); then echo "${parts[0]}"; fi
  done <<< "$lines"
}

cmd_issues_in_progress() {
  local lines line
  load_labels
  [[ -n "${L_in_progress:-}" ]] || die "labels.in_progress が設定に無い"
  lines="$(_issues_with_label "$L_in_progress")"
  while IFS= read -r line; do
    if [[ -n "$line" ]]; then echo "${line%%$'\t'*}"; fi
  done <<< "$lines"
}

cmd_last_labeled() {
  need_num "${1:-}"
  local L lines name at last=""
  L="$(label_arg "${2:-}")"
  lines="$(_gh api --paginate "$(repo_path)/issues/$1/timeline?per_page=100" \
    --jq '.[] | select(.event == "labeled") | [.label.name, .created_at] | join("\t")')"
  while IFS=$'\t' read -r name at; do
    if [[ "$name" == "$L" ]]; then last="$at"; fi
  done <<< "$lines"
  if [[ -n "$last" ]]; then echo "$last"; fi
  return 0
}

cmd_pr_open_release() {
  _gh api --paginate "$(repo_path)/pulls?state=open&per_page=100" \
    --jq '.[] | select(.head.ref | startswith("release/")) | .number'
}

cmd_issue_create() {
  local title="" bodyf="" R
  local -a args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title)     [[ $# -ge 2 ]] || usage "--title に値が無い"; title="$2"; shift 2 ;;
      --body-file) [[ $# -ge 2 ]] || usage "--body-file に値が無い"; bodyf="$2"; shift 2 ;;
      --label)     [[ $# -ge 2 ]] || usage "--label に値が無い"; args+=(-f "labels[]=$(label_arg "$2")"); shift 2 ;;
      *) usage "issue-create: 不明な引数 '$1'" ;;
    esac
  done
  [[ -n "$title" && -n "$bodyf" ]] || usage "issue-create --title T --body-file F [--label L ...]"
  R="$(repo_path)"
  if [[ "$bodyf" == "-" ]]; then
    _gh api -X POST "$R/issues" -f title="$title" -F body=@- ${args[@]+"${args[@]}"} --jq '.number'
  else
    [[ -f "$bodyf" ]] || die "ファイルが無い: $bodyf"
    _gh api -X POST "$R/issues" -f title="$title" -F body=@- ${args[@]+"${args[@]}"} --jq '.number' < "$bodyf"
  fi
}

cmd_comment_find() {
  need_num "${1:-}"
  local prefix="${2:-}" lit ids n=0 line
  [[ -n "$prefix" ]] || usage "comment-find N <prefix>"
  lit="$(jqstr "$prefix")"
  ids="$(_gh api --paginate "$(repo_path)/issues/$1/comments?per_page=100" \
    --jq ".[] | select((.body // \"\") | startswith($lit)) | .id")"
  while IFS= read -r line; do
    if [[ -n "$line" ]]; then n=$((n + 1)); fi
  done <<< "$ids"
  echo "$n"
}

# ---------------------------------------------------------------------------------------------
main() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    repo)               repo_slug ;;
    api)                export MSYS_NO_PATHCONV=1; exec gh api "$@" ;;
    label-name)         [[ $# -ge 1 ]] || usage "label-name <key>"; label_of_key "$1"; echo ;;
    ensure-labels)      cmd_ensure_labels ;;
    status-issue)       cmd_status_issue ;;
    issue-get)          cmd_issue_get "$@" ;;
    issue-labels)       cmd_issue_labels "$@" ;;
    label-add)          cmd_label_add "$@" ;;
    label-del)          cmd_label_del "$@" ;;
    comment)            cmd_comment "$@" ;;
    issues-ready)       cmd_issues_ready ;;
    issues-in-progress) cmd_issues_in_progress ;;
    last-labeled)       cmd_last_labeled "$@" ;;
    pr-open-release)    cmd_pr_open_release ;;
    issue-create)       cmd_issue_create "$@" ;;
    comment-find)       cmd_comment_find "$@" ;;
    ""|-h|--help|help)  usage "サブコマンドを指定する" ;;
    *)                  usage "不明なサブコマンド '$cmd'" ;;
  esac
}

main "$@"
