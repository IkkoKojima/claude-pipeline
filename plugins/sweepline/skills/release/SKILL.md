---
name: release
description: 配信セッション (deploy 環境、オーナー起動)。対象 SHA の固定 → 検証 → 前回成功版とチェックリスト → 版上げ → リリースノート (オーナー清書) → release PR → providers で配信 → 実機確認の結果処理。引数 minor|patch|X.Y.Z[+N]、--scope <provider type,...>、--dry-run。配信先は sweepline.toml の [[release.providers]] と CLAUDE.md の ## release 節
---

# /sweepline:release <minor|patch|X.Y.Z[+N]> [--scope type1,type2] [--dry-run]

オーナーが deploy 環境 (`SWEEPLINE_ENV=deploy`) で起動する。**状態はリリース issue `[release] v<ver>` に持つ** (セッションは GitHub Release を作れない)。
待ちに入る前に必ず issue 本文を更新し、再開時は issue 本文の「未」の工程だけを実行する。GitHub 操作は REST と GitHub MCP のみ。

```bash
KIT="${CLAUDE_PLUGIN_ROOT:-}"; [ -d "$KIT/scripts" ] || KIT=/opt/sweepline/kit/plugins/sweepline
[ -d "$KIT/scripts" ] || KIT="$(ls -d ~/.claude/plugins/marketplaces/*/plugins/sweepline 2>/dev/null | head -1)"   # marketplace clone (marketplace update で最新になる) を優先
[ -d "$KIT/scripts" ] || KIT="$(dirname "$(dirname "$(find ~/.claude/plugins -path '*sweepline*' -path '*/scripts/sweepline_config.py' 2>/dev/null | head -1)")")"
PC="python3 $KIT/scripts/sweepline_config.py"; GH="bash $KIT/scripts/gh.sh"
SLUG="$($PC repo)"; R="repos/$SLUG"; PROVIDERS="$($PC get release.providers)"; NOTES="$($PC get release.notes_dir)"
L_RELEASE="$($GH label-name release)"; L_READY="$($GH label-name ready)"; L_MU="$($GH label-name merged_unverified)"
START_BRANCH="$(git rev-parse --abbrev-ref HEAD)"; mkdir -p .sweepline
echo "SWEEPLINE_ENV=${SWEEPLINE_ENV:-unset} providers=$(echo "$PROVIDERS" | python3 -c 'import json,sys; print(",".join(p["type"] for p in json.load(sys.stdin)))')"
git fetch origin main --tags --quiet
```

`PROVIDERS` は JSON 配列。以降「各 provider」は配列の index 順で、`PROVIDER_INDEX=<i>` を渡して provider スクリプトを呼ぶ。
`--scope` があれば、その type の provider だけを対象にする (無い type を指定したら止まる)。

## 0. 前提と preflight

- `SWEEPLINE_ENV=deploy` でなければ止まる。この環境では impl を動かさない (修正が要るなら impl 環境で `/sweepline:impl` → `/sweepline:release patch` を新しく)
- 各 provider の preflight: `PROVIDER_INDEX=<i> bash $KIT/scripts/providers/<type>.sh preflight` (`PREFLIGHT=ok|ng` を返す)。`supabase-mcp` はスクリプトではなく
  **Supabase コネクター (MCP ツール `list_migrations` 等) が見えるか**で判定する (セッション作成時にオーナーが有効にする)
- preflight が NG の provider は「NG (理由)」として控える。**その provider に配信対象の差分が無ければ (手順 6 の `only_if_changed`) 問題ない**。差分があるのに NG なら
  手順 6 でその provider を「失敗 (preflight)」として記録し、オーナーに資格の登録を依頼する (他の provider は進める)

## 1. 対象 SHA の固定と検証

- `TARGET=$(git rev-parse origin/main)`。以降 main が進んでも TARGET で作業する
- `$GH issues-in-progress` に issue があれば警告 (続行可)。`$GH pr-open-release` があれば止まる (前回の release が未完)
- `git checkout -q $TARGET` → `bash $KIT/scripts/verify.sh --always`。赤なら `[main-red] <テスト名>` を `$L_READY` で起票して終了 (手順 9 で元ブランチに戻す)

## 2. 前回成功版 (PREV)、パイプライン差分ゲート、チェックリスト

- リリース issue の検索: `$GH api "$R/issues?state=all&labels=$L_RELEASE&per_page=20" --jq '.[] | select(.title | startswith("[release] ")) | "\(.number)\t\(.state)\t\(.title)"'`
  → 本文 (`$GH issue-get <n>`) の「配信状態」を読み、**全 provider が「済」か「スキップ」(「失敗」が 1 つも無い) の最新の issue** を選ぶ。open / closed は問わない
  (open は実機確認が未処理なだけ)。その `RELEASE_SHA` を `PREV` にする。該当が無ければ最新の `v*` タグ (`git describe --tags --abbrev=0 --match 'v*'`)
- **パイプライン自身の差分ゲート**: `git diff --stat $PREV $TARGET -- sweepline.toml .claude .github codemagic.yaml` に差分があれば表示し、オーナーが「続行」と答えるまで進まない
  (main 由来のコードが資格付き環境で動く前の確認。`--dry-run` では表示だけして続行)
- `python3 $KIT/scripts/verify_checklist.py generate --since $PREV --until $TARGET --out .sweepline/checklist.md`
- **`--dry-run` はここで終了**: preflight の結果、PREV / TARGET、差分ゲートの結果、`.sweepline/checklist.md` の内容をチャットに表示する
  (無人で呼ばれた場合は固定 issue `$($GH status-issue)` に 1 コメント)。手順 9 で元ブランチに戻す

## 3. 版上げとリリース issue

- `$PC version bump <minor|patch|X.Y.Z[+N]>` → `NEW=<ver>` (`release.version_stack` のファイルを書き換える)。minor / patch はユーザーに見える変化かで判断
- ブランチ `release/v$NEW` を TARGET から切って push (sweep のリリースロック)
- リリース issue を `$GH issue-create --title "[release] v$NEW" --body-file .sweepline/release-issue.md --label "$L_RELEASE"`。本文:
  ```
  TARGET: <sha> / PREV: <sha or tag> / providers: <types (--scope 適用後)>
  ## 配信状態
  | 対象 | 状態 | ID / URL | 時刻 |
  | release PR | 未 | | |
  | <provider type> ... | 未 | | |
  ## チェックリスト
  <.sweepline/checklist.md>
  ```
  以降の更新は `$GH api -X PATCH $R/issues/<n> -F body=@.sweepline/release-issue.md`。状態の語彙は **未 / 済 / スキップ (理由) / 失敗 (理由)** に固定する

## 4. リリースノート (下書き → オーナー清書 → 英訳 → render 検証)

- `bash $KIT/scripts/release_notes.sh ensure $NEW` (無ければ draft) → `$NOTES/$NEW.md` を PREV..TARGET のマージ PR の「変更点」で肉付け
- **オーナーに提示して待つ** (待つ前に下書きを issue 本文の「ノート (下書き)」節に保存)。返ってきた文面をそのまま保存
- `release_notes.sh en-ensure $NEW` → 英訳を軽く確認 → `release_notes.sh render $NEW` (provider の `notes_limits` で文字数検証)。超過は直して再提示
- `release.notes_dir` が空のプロジェクトはこの手順をスキップ

## 5. release PR → squash マージ

- `git add <version ファイル> $NOTES/` → `git commit -m "chore(release): bump version to $NEW"` → push
- MCP `create_pull_request` (base main、head `release/v$NEW`、title `chore(release): v$NEW`、body = ノート要約 + `Refs #<release issue>`)
- MCP `merge_pull_request` (squash、expectedHeadSha)。`RELEASE_SHA=$(git rev-parse origin/main)` を issue に記録。**タグはここでは作らない** (provider に任せる)

## 6. 配信 (providers を index 順に)

各 provider について:

1. **差分条件**: provider 定義に `only_if_changed = ["glob", ...]` があり、`git diff --name-only $PREV $RELEASE_SHA` にその glob に一致するファイルが無ければ
   **「スキップ (差分なし)」を issue に記録して次へ** (`--scope` で明示指定された場合も同じ)
2. preflight が NG だった provider は「失敗 (preflight: <理由>)」と記録して次へ (オーナーへの依頼を最後にまとめる)
3. 起動と監視:
   ```bash
   PROVIDER_INDEX=<i> bash $KIT/scripts/providers/<type>.sh deploy "$NEW" "$RELEASE_SHA"      # ID=... URL=... を返す
   PROVIDER_INDEX=<i> bash $KIT/scripts/providers/<type>.sh status "<ID>"                    # STATUS=running|finished|failed
   ```
   `supabase-mcp` は `$KIT/scripts/providers/supabase-mcp.md` の手順 (承認バンドル → オーナーの「適用して <8桁>」→ MCP `apply_migration`)
4. CLAUDE.md `## release` 節に provider に無い手順があれば、その記述に従う (`shell` provider で表現できるならそちらへ)
5. 結果 (ID / URL / 時刻 / 済・失敗) を issue の「配信状態」に記録。失敗した provider は同じ版で再実行しない (再実行は `/sweepline:release patch` で版を上げて手順 3 から)

main にマージされる web / DB の変更は後方互換 (既存バイナリが動き続ける) が前提。破壊的ならオーナーに確認してから。

## 7. 配信完了と実機確認

- 全 provider の完了を issue に記録し、オーナーにチェックリスト (手順 2) を提示して待つ (待つ前に issue 本文を最新にする)
- 結果 (例: 「#27 OK / #28 NG (Android): 決定ボタンが反応しない」) を処理:
  - OK → `$GH api -X PATCH $R/issues/<n> -f state=closed` + `$GH label-del <n> "$L_MU"`
  - NG → オーナーの言葉をそのまま本文にし、再現条件・対象版・OS を付けた修正 issue を `$L_READY` で作成 (元 issue にリンク。元 issue は open のまま)
- 「失敗」が無ければリリース issue を close。失敗があれば open のまま「失敗」を残す (次回の PREV 判定で除外される)
- 本番昇格 (ストアの製品版 / 審査提出) は手動

## 8. 再開

リリース issue の「配信状態」を読み、「未」の工程だけ順に実行する。`release/v$NEW` ブランチと PR が既にあればそれを使う。

## 9. 後始末

終了時 (dry-run / 中断を含む) に `git checkout -q "$START_BRANCH"` で元のブランチに戻す。`.sweepline/` は gitignore 済みなので消さなくてよい。
