#!/bin/bash
# release_notes.sh — リリースノート管理 (pipeline プラグイン版。pokemonitor の .claude/skills/deploy/release_notes.sh の移植)。
#
# 単一ソース <notes_dir>/<version>.md (日本語) と <version>.en.md (英訳) から、ストア文面 (Play changelog /
# TestFlight What to Test など) を render して文字数を検証する。判断・清書・翻訳はセッション (SKILL) 側、
# 決め打ちの生成と検証はこのスクリプト。
#
# サブコマンド:
#   ensure    [<version>]                     無ければ draft、あれば no-op (冪等)
#   draft     [<version>] [--from R] [--force] git log から日本語の下書きを生成 (既存は上書きしない)
#   en-ensure [<version>]                     英訳 <version>.en.md の雛形 (無ければ)。front matter を ja から継承し ja の本文を下地に入れる
#   render    [<version>]                     ja / en を render して表示し <notes_dir>/.rendered/ に書き、上限で検証
#   validate  [<version>]                     検証のみ (書き込みなし)
#   range     [--from R]                      下書きに使う範囲
#
# version 省略時は pipeline_config.py version get (release.version_stack の版)。notes_dir は pipeline.toml の
# release.notes_dir (既定 release_notes)。書式: front matter (version / build / date / locales) + `## 見出し` + `- 箇条書き`。
# 文字数の上限は release.providers の各 provider の `notes_limits` (scripts/providers/<type>.sh notes_limits) を集めたもの
# (同じチャネルは小さい方)。どの provider も出さなければ PLAY=500 TESTFLIGHT=4000。
#
# 機械可読出力:
#   RANGE=<base>..HEAD
#   LIMIT_<CHANNEL>=<n>
#   VALIDATE:    play=<n>/500 testflight=<n>/4000 status=<ok|error|missing>
#   VALIDATE_EN: play=<n>/500 testflight=<n>/4000 status=<ok|error|missing|untranslated>
#   DRAFTED=<path> / EXISTS=<path> / EN_DRAFTED=<path> / EN_EXISTS=<path> / RENDER_FILE=<path>
# 上限超過と英訳への日本語の残りは exit 1 (render はファイルを書いて表示してから落ちる)。英訳ファイルが無いのは status=missing (可)。

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDERS_DIR="$HERE/providers"
export PYTHONIOENCODING=utf-8

PY="${PIPELINE_PYTHON:-}"
if [[ -z "$PY" ]]; then
  if command -v python3 >/dev/null 2>&1; then PY=python3; else PY=python; fi
fi

die()  { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARN: $*" >&2; }
cfg()  { "$PY" "$HERE/pipeline_config.py" ${PIPELINE_ROOT:+--root "$PIPELINE_ROOT"} "$@" | tr -d '\r'; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

if [[ -n "${PIPELINE_ROOT:-}" ]]; then
  REPO_ROOT="$PIPELINE_ROOT"
else
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
cd "$REPO_ROOT"
export PIPELINE_ROOT="$REPO_ROOT"   # provider の子プロセスも同じ設定を読む

NOTES_DIR="$(cfg get release.notes_dir --default release_notes)" || NOTES_DIR=release_notes
NOTES_DIR="${NOTES_DIR%/}"
[[ -n "$NOTES_DIR" ]] || NOTES_DIR=release_notes

CURRENT_VERSION=""
current_version() {
  if [[ -z "$CURRENT_VERSION" ]]; then
    CURRENT_VERSION="$(cfg version get 2>/dev/null)" || CURRENT_VERSION=""
  fi
  printf '%s' "$CURRENT_VERSION"
}
version_or_current() {
  local v="${1:-}"
  if [[ -z "$v" ]]; then v="$(current_version)"; fi
  [[ -n "$v" ]] || die "版を決められない (pipeline.toml の release.version_stack を確認するか <version> を渡す)"
  printf '%s' "$v"
}
# X.Y.Z+N の N (無ければ空)
build_of() { if [[ "$1" == *+* ]]; then printf '%s' "${1##*+}"; fi; }

# 版を持つファイル (release.version_stack の stack の version.file)。無ければ空
version_file() {
  cfg json 2>/dev/null | "$PY" -c '
import json, sys
try:
    c = json.loads(sys.stdin.buffer.read().decode("utf-8"))
except ValueError:
    sys.exit(0)
vs = (c.get("release") or {}).get("version_stack", "")
for s in c.get("stacks", []):
    if s.get("name") == vs and s.get("version"):
        p = s.get("path", ".") or "."
        f = s["version"]["file"]
        sys.stdout.write(f if p == "." else p.rstrip("/") + "/" + f)
        break
' 2>/dev/null | tr -d '\r' || true
}

# 文字数 (code point 数。UTF-8 前提でバイト数ではない)
count_chars() {
  perl -CSDA -e 'local $/; my $t=<STDIN>; $t //= ""; print length($t);'
}

src_path()    { printf '%s/%s.md' "$NOTES_DIR" "$1"; }
en_src_path() { printf '%s/%s.en.md' "$NOTES_DIR" "$1"; }
render_dir()  { printf '%s/.rendered' "$NOTES_DIR"; }

# ---- 上限 (provider の notes_limits) ----------------------------------------------------------
LIMIT_KEYS=""
LIMITS_LOADED=0
add_limit() {
  local k="$1" v="$2" var cur
  var="LIMIT_$k"
  cur="${!var:-}"
  if [[ -z "$cur" ]]; then
    printf -v "$var" '%s' "$v"
    LIMIT_KEYS="${LIMIT_KEYS:+$LIMIT_KEYS }$k"
  elif (( v < cur )); then
    printf -v "$var" '%s' "$v"
  fi
}
collect_limits() {
  local types t i=0 out line
  (( LIMITS_LOADED )) && return 0
  LIMITS_LOADED=1
  types="$(cfg get release.providers --default '[]' | "$PY" -c '
import json, sys
try:
    lst = json.loads(sys.stdin.buffer.read().decode("utf-8") or "[]")
except ValueError:
    lst = []
sys.stdout.write("".join(((x.get("type") or "-") if isinstance(x, dict) else "-") + "\n" for x in lst))
' | tr -d '\r')" || types=""
  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    if [[ "$t" =~ ^[A-Za-z0-9_-]+$ && -f "$PROVIDERS_DIR/$t.sh" ]]; then
      if out="$(PROVIDER_INDEX="$i" bash "$PROVIDERS_DIR/$t.sh" notes_limits)"; then
        while IFS= read -r line; do
          if [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=([0-9]+)$ ]]; then add_limit "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"; fi
        done <<< "$out"
      else
        warn "provider $t (release.providers[$i]) の notes_limits が失敗。上限の収集から外す"
      fi
    fi
    i=$((i + 1))
  done <<< "$types"
  if [[ -z "$LIMIT_KEYS" ]]; then
    add_limit PLAY 500
    add_limit TESTFLIGHT 4000
  fi
}
limits_text() {  # play=500 / testflight=4000
  local k var out=""
  for k in $LIMIT_KEYS; do
    var="LIMIT_$k"
    out="${out:+$out / }$(lower "$k")=${!var}"
  done
  printf '%s' "$out"
}

# ---- 範囲解決 (タグ未整備のブートストラップ対応) ------------------------------------------------
resolve_base() {
  local from="${1:-}" tag vf second count
  if [[ -n "$from" ]]; then echo "$from"; return; fi
  # (1) 最新の v* タグ
  tag="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
  if [[ -n "$tag" ]]; then echo "$tag"; return; fi
  # (2) bootstrap: 版ファイルを触る chore(release) コミットの 2 件目 (= 前回リリース)
  vf="$(version_file)"
  if [[ -n "$vf" ]]; then
    second="$(git log --grep='^chore(release)' --format='%H' -- "$vf" 2>/dev/null | sed -n '2p' || true)"
  else
    second="$(git log --grep='^chore(release)' --format='%H' 2>/dev/null | sed -n '2p' || true)"
  fi
  if [[ -n "$second" ]]; then echo "$second"; return; fi
  # (3) hard fallback
  count="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
  if [[ "$count" -gt 30 ]]; then
    warn "リリース基点を特定できず。直近 30 件を範囲にします。"
    echo "HEAD~30"
  else
    warn "リリース基点を特定できず。全履歴を範囲にします。"
    git rev-list --max-parents=0 HEAD | head -n1
  fi
}

# commit subject から type(scope): と社内コードネーム (先頭 / 末尾) を除き "- " 箇条書きに整える
_strip_subjects() {
  sed -E 's/^(feat|fix)(\([^)]*\))?:[[:space:]]*//' \
  | sed -E 's#^([A-Z0-9]+(-[A-Z0-9]+)*/)+##' \
  | sed -E 's/[[:space:]]*\([A-Z0-9/_-]+\)[[:space:]]*$//' \
  | sed -E 's/^/- /'
}

# ---- 下書き生成 ---------------------------------------------------------------------------------
cmd_draft() {
  local version="" from="" force=0 build src base range subjects fixes feats
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from)  from="${2:-}"; shift 2 ;;
      --force) force=1; shift ;;
      *)       version="$1"; shift ;;
    esac
  done
  version="$(version_or_current "$version")"
  build="$(build_of "$version")"
  src="$(src_path "$version")"

  if [[ -f "$src" && "$force" -eq 0 ]]; then
    echo "EXISTS=$src"
    return 0
  fi

  base="$(resolve_base "$from")"
  range="${base}..HEAD"
  echo "RANGE=$range"
  collect_limits

  subjects="$(git log "$range" --no-merges --format='%s' 2>/dev/null || true)"
  # fix → バグ修正 / feat → 改善 に振り分け、type(scope): と社内コードネームを除去
  fixes="$(printf '%s\n' "$subjects" | grep -E '^fix(\([^)]*\))?:'  | _strip_subjects || true)"
  feats="$(printf '%s\n' "$subjects" | grep -E '^feat(\([^)]*\))?:' | _strip_subjects || true)"

  mkdir -p "$(dirname "$src")"
  {
    echo "---"
    echo "version: $version"
    if [[ -n "$build" ]]; then echo "build: $build"; fi
    echo "date: $(date +%F)   # リリース確定日 (必要なら修正)"
    echo "locales: [ja]"
    echo "---"
    echo ""
    if [[ -z "$fixes" && -z "$feats" ]]; then
      echo "## 変更点"
      echo ""
      echo "- (ユーザー向けの変更点を記入)"
      echo ""
    else
      if [[ -n "$fixes" ]]; then
        echo "## バグ修正"; echo ""; echo "$fixes"; echo ""
      fi
      if [[ -n "$feats" ]]; then
        echo "## 改善"; echo ""; echo "$feats"; echo ""
      fi
    fi
    echo "<!-- 下書きは git log ($range) 由来。見出し (## ) + 箇条書き (- ) で自由に構成してよい。"
    echo "     ストアに出る文面なのでユーザー目線に整える。上限: $(limits_text) 文字。 -->"
  } > "$src"

  echo "DRAFTED=$src"
}

cmd_ensure() {
  local version src
  version="$(version_or_current "${1:-}")"
  src="$(src_path "$version")"
  if [[ -f "$src" ]]; then
    echo "EXISTS=$src"
    return 0
  fi
  cmd_draft "$version"
}

# ---- パース (render / validate 共通) ------------------------------------------------------------
# release-note md を整形テキスト (RENDERED) + 文字数 (NOTE_N) にする。引数: version, srcfile, locale(ja|en)。
# front matter の version / build が版と一致することを検証する。srcfile 不在は return 2、形式不正は die。装飾は locale で切替:
#   ja → 見出し【…】/ 箇条書き ・   (ストア日本語文面の従来仕様)
#   en → 見出しそのまま / 箇条書き -  (英語ストア文面として自然な形)
RENDERED=""
NOTE_N=0
parse_note() {
  local version="$1" src="$2" locale="${3:-ja}"
  local build fm fm_version fm_build cur hlead="【" htail="】" bullet="・"
  build="$(build_of "$version")"

  [[ -f "$src" ]] || return 2

  fm="$(awk '/^---$/{c++; next} c==1{print} c>=2{exit}' "$src")"
  fm_version="$(printf '%s\n' "$fm" | awk -F': *' '/^version:/{print $2; exit}' | sed 's/[[:space:]]*#.*$//' | tr -d '[:space:]')"
  fm_build="$(printf '%s\n' "$fm" | awk -F': *' '/^build:/{print $2; exit}' | sed 's/[[:space:]]*#.*$//' | tr -d '[:space:]')"

  [[ "$fm_version" == "$version" ]] || die "[$locale] front matter の version ($fm_version) がファイル名の版 ($version) と不一致。版違い / 版上げ忘れ?"
  if [[ -n "$build" || -n "$fm_build" ]]; then
    [[ "$fm_build" == "$build" ]] || die "[$locale] front matter の build ($fm_build) が版の +N ($build) と不一致。"
  fi

  # 版ファイルとの整合は warn のみ (バックフィル / テストを妨げない)。en は ja に追従する派生なので見ない
  if [[ "$locale" == "ja" ]]; then
    cur="$(current_version)"
    if [[ -n "$cur" && "$version" != "$cur" ]]; then warn "対象版 ($version) が現在の版 ($cur) と異なります。"; fi
  fi

  if [[ "$locale" == "en" ]]; then hlead=""; htail=""; bullet="- "; fi

  # front matter 以降の本文を整形: 見出し ## → hlead…htail、箇条書き - → bullet、HTML コメント / 空行は無視
  RENDERED="$(awk -v hlead="$hlead" -v htail="$htail" -v bullet="$bullet" '
    BEGIN { body=0; fmcount=0; incomment=0; first=1 }
    body==0 {
      if ($0 ~ /^---$/) { fmcount++; if (fmcount>=2) body=1 }
      next
    }
    {
      line=$0
      if (incomment) { if (line ~ /-->/) incomment=0; next }
      if (line ~ /<!--/) { if (line !~ /-->/) incomment=1; next }
      if (line ~ /^#+[ \t]+/) {
        h=line; sub(/^#+[ \t]+/,"",h); sub(/[ \t]+$/,"",h)
        if (h != "") { if (!first) print ""; print hlead h htail; first=0 }
        next
      }
      if (line ~ /^[-*][ \t]+/) {
        b=line; sub(/^[-*][ \t]+/,"",b); sub(/[ \t]+$/,"",b)
        if (b != "") { print bullet b; first=0 }
        next
      }
      if (line ~ /^[ \t]*$/) next
      print line; first=0
    }
  ' "$src")"

  [[ -n "$RENDERED" ]] || die "[$locale] 本文 (見出し / 箇条書き) が空です。最低 1 項目を記入してください。"
  NOTE_N="$(printf '%s' "$RENDERED" | count_chars)"
}

# RENDERED に日本語 (漢字 / かな) が残っていれば真 (英訳漏れのトリップワイヤー)
rendered_has_cjk() {
  local rc=0
  printf '%s' "$RENDERED" | perl -CSDA -0777 -ne 'exit(/\p{Han}|\p{Hiragana}|\p{Katakana}/ ? 1 : 0)' || rc=$?
  [[ "$rc" -ne 0 ]]
}

# validate_line <prefix> <n> <status_if_ok> — 上限ごとの n/limit を 1 行で出し、超過チャネルを OVER に入れる
OVER=""
validate_line() {
  local prefix="$1" n="$2" okst="${3:-ok}" k var parts="" st
  OVER=""
  for k in $LIMIT_KEYS; do
    var="LIMIT_$k"
    parts="${parts}$(lower "$k")=${n}/${!var} "
    if (( n > ${!var} )); then OVER="${OVER:+$OVER, }$(lower "$k") ${n}/${!var}"; fi
  done
  st="$okst"
  if [[ -n "$OVER" && "$okst" == ok ]]; then st=error; fi
  echo "$prefix ${parts}status=$st"
}
missing_line() {  # prefix
  local k var parts=""
  for k in $LIMIT_KEYS; do
    var="LIMIT_$k"
    parts="${parts}$(lower "$k")=0/${!var} "
  done
  echo "$1 ${parts}status=missing"
}

print_block() {  # locale n
  local k var chans=""
  for k in $LIMIT_KEYS; do
    var="LIMIT_$k"
    chans="${chans:+$chans, }$(lower "$k") $2/${!var}"
  done
  echo "=== render $1 ($chans) ==="
  printf '%s\n' "$RENDERED"
  echo "=== /render $1 ==="
}

# ---- render / validate ---------------------------------------------------------------------------
# write=1 なら .rendered/ に書いて表示する。戻り値: 0 = 問題なし、1 = 上限超過 / 英訳漏れ (呼び出し側で die)
FAILS=""
process_version() {
  local version="$1" write="$2" rc=0 k var f cjk=0 rdir
  rdir="$(render_dir)"
  collect_limits
  for k in $LIMIT_KEYS; do
    var="LIMIT_$k"
    echo "LIMIT_$k=${!var}"
  done

  # ja
  RENDERED=""; NOTE_N=0
  parse_note "$version" "$(src_path "$version")" ja || rc=$?
  if [[ "$rc" -eq 2 ]]; then
    warn "$(src_path "$version") が無い (リリースノート未記入)。"
    missing_line "VALIDATE:"
  else
    if [[ "$write" == 1 ]]; then
      mkdir -p "$rdir"
      for k in $LIMIT_KEYS; do
        f="$rdir/$(lower "$k").txt"
        printf '%s\n' "$RENDERED" > "$f"
        echo "RENDER_FILE=$f"
      done
      print_block ja "$NOTE_N"
    fi
    validate_line "VALIDATE:" "$NOTE_N" ok
    if [[ -n "$OVER" ]]; then FAILS="${FAILS:+$FAILS; }[ja] 上限超過 ($OVER)。短くしてください。"; fi
  fi

  # en (任意)
  rc=0
  RENDERED=""; NOTE_N=0
  parse_note "$version" "$(en_src_path "$version")" en || rc=$?
  if [[ "$rc" -eq 2 ]]; then
    missing_line "VALIDATE_EN:"
  else
    if rendered_has_cjk; then cjk=1; fi
    if [[ "$write" == 1 && "$cjk" -eq 0 ]]; then
      mkdir -p "$rdir"
      for k in $LIMIT_KEYS; do
        f="$rdir/$(lower "$k").en.txt"
        printf '%s\n' "$RENDERED" > "$f"
        echo "RENDER_FILE=$f"
      done
      print_block en "$NOTE_N"
    fi
    if [[ "$cjk" -eq 1 ]]; then
      validate_line "VALIDATE_EN:" "$NOTE_N" untranslated
      FAILS="${FAILS:+$FAILS; }[en] 英訳に日本語 (漢字 / かな) が残っています。翻訳を完了してください。"
    else
      validate_line "VALIDATE_EN:" "$NOTE_N" ok
    fi
    if [[ -n "$OVER" ]]; then FAILS="${FAILS:+$FAILS; }[en] 上限超過 ($OVER)。短くしてください。"; fi
  fi
  [[ -z "$FAILS" ]]
}

cmd_render() {
  local version
  version="$(version_or_current "${1:-}")"
  process_version "$version" 1 || die "$FAILS"
}

cmd_validate() {
  local version
  version="$(version_or_current "${1:-}")"
  process_version "$version" 0 || die "$FAILS"
}

# 英訳ファイルの雛形を作る (無ければ)。front matter を ja から引き継ぎ、ja の本文を翻訳の下地として入れる
cmd_en_ensure() {
  local version build ja en seed d
  version="$(version_or_current "${1:-}")"
  build="$(build_of "$version")"
  ja="$(src_path "$version")"
  en="$(en_src_path "$version")"

  if [[ -f "$en" ]]; then
    echo "EN_EXISTS=$en"
    return 0
  fi
  [[ -f "$ja" ]] || die "英訳の元になる $ja が無い。先に日本語ノートを用意すること。"
  collect_limits

  # ja 本文の見出し / 箇条書きだけを下地として抜き出す (front matter / コメント除外)
  seed="$(awk '
    BEGIN { body=0; fmcount=0; incomment=0 }
    body==0 { if ($0 ~ /^---$/) { fmcount++; if (fmcount>=2) body=1 } next }
    { if (incomment) { if ($0 ~ /-->/) incomment=0; next }
      if ($0 ~ /<!--/) { if ($0 !~ /-->/) incomment=1; next }
      if ($0 ~ /^[ \t]*$/) next
      print }
  ' "$ja")"

  d="$(awk -F': *' '/^date:/{print $2; exit}' "$ja" | sed 's/[[:space:]]*#.*$//' | tr -d '[:space:]')"
  [[ -n "$d" ]] || d="$(date +%F)"

  {
    echo "---"
    echo "version: $version"
    if [[ -n "$build" ]]; then echo "build: $build"; fi
    echo "date: $d"
    echo "locales: [en]"
    echo "---"
    echo ""
    echo "<!-- ↓は日本語の下地。自然な英語に翻訳して置き換える (日本語が残ると render が失敗する)。 -->"
    printf '%s\n' "$seed"
    echo ""
    echo "<!-- English release note. Bullets (- ) preferred. Limits: $(limits_text) characters. -->"
  } > "$en"

  echo "EN_DRAFTED=$en"
}

cmd_range() {
  local from="" base
  if [[ "${1:-}" == "--from" ]]; then from="${2:-}"; fi
  base="$(resolve_base "$from")"
  echo "RANGE=${base}..HEAD"
}

main() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    ensure)    cmd_ensure    "$@" ;;
    draft)     cmd_draft     "$@" ;;
    en-ensure) cmd_en_ensure "$@" ;;
    render)    cmd_render    "$@" ;;
    validate)  cmd_validate  "$@" ;;
    range)     cmd_range     "$@" ;;
    *) echo "使い方: release_notes.sh {ensure|draft|en-ensure|render|validate|range} [<version>] [--from <ref>] [--force]" >&2; exit 2 ;;
  esac
}

main "$@"
