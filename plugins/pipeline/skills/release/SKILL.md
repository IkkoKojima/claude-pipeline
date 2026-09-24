---
name: release
description: 配信セッション (deploy 環境、オーナー起動)。対象 SHA の固定 → 検証 → チェックリスト → 版上げ → リリースノート (オーナー清書) → release PR → providers で配信 → 実機確認の結果処理。引数 minor|patch|X.Y.Z[+N]、--scope <provider,...>、--dry-run。配信先は pipeline.toml の [[release.providers]] と CLAUDE.md の ## release 節
---

# /pipeline:release <minor|patch|X.Y.Z[+N]> [--scope p1,p2] [--dry-run]

オーナーが deploy 環境 (`PIPELINE_ENV=deploy`) で起動する。**状態はリリース issue `[release] v<ver>` に持つ** (セッションは GitHub Release を作れない)。
待ちに入る前に必ず issue 本文を更新し、再開時は issue 本文の「未」の工程だけを実行する。GitHub 操作は REST と GitHub MCP のみ。

```bash
KIT="${CLAUDE_PLUGIN_ROOT:-/opt/pipeline/kit/plugins/pipeline}"; PC="python3 $KIT/scripts/pipeline_config.py"; GH="bash $KIT/scripts/gh.sh"
SLUG="$($PC repo)"; R="repos/$SLUG"; L="$($PC labels)"; PROVIDERS="$($PC get release.providers)"; NOTES="$($PC get release.notes_dir)"
echo "PIPELINE_ENV=${PIPELINE_ENV:-unset} providers=$(echo "$PROVIDERS" | python3 -c 'import json,sys; print(",".join(p["type"] for p in json.load(sys.stdin)))')"
git fetch origin main --tags --quiet; mkdir -p .pipeline
```

## 0. 前提

- `PIPELINE_ENV=deploy` でなければ止まる。この環境では impl を動かさない (修正が要るなら impl 環境で `/pipeline:impl` → `/pipeline:release patch` を新しく)
- **パイプライン自身の差分ゲート**: PREV (手順 2) から `pipeline.toml` / `.claude/**` / `.github/**` / `codemagic.yaml` に差分があれば表示して、オーナーが「続行」と答えるまで進まない
- 各 provider の `bash $KIT/scripts/providers/<type>.sh preflight` を回し、NG があれば表示 (資格の貼り忘れはここで分かる)。`supabase-mcp` は
  Supabase コネクターが有効か (MCP ツールが見えるか) を確認
- `--scope` があれば、その provider だけを対象にする

## 1. 対象 SHA の固定と検証

- `TARGET=$(git rev-parse origin/main)`。以降 main が進んでも TARGET で作業する
- in_progress の issue があれば警告 (続行可)
- `git checkout $TARGET` → `bash $KIT/scripts/verify.sh --always`。赤なら `[main-red] <テスト名>` を ready で起票して終了

## 2. 前回成功版とチェックリスト

- PREV = 「配信状態」が全 provider 成功の最新リリース issue の RELEASE_SHA (無ければ最新の `v*` タグ)。
  検索: `$GH api "$R/issues?state=all&labels=<labels.release>&per_page=20" --jq '.[] | select(.title | startswith("[release] "))'`
- `python3 $KIT/scripts/verify_checklist.py generate --since $PREV --until $TARGET --out .pipeline/checklist.md`
- `--dry-run` はここで表示して終了

## 3. 版上げとリリース issue

- `$PC version bump <minor|patch|X.Y.Z[+N]>` → `NEW=<ver>` (`release.version_stack` のファイルを書き換える)。minor / patch はユーザーに見える変化かで判断
- ブランチ `release/v$NEW` を TARGET から切って push (sweep のリリースロック)
- リリース issue を `$GH issue-create --title "[release] v$NEW" --body-file .pipeline/release-issue.md --label <labels.release>`。本文:
  ```
  TARGET: <sha> / PREV: <sha or tag> / providers: <types>
  ## 配信状態
  | 対象 | 状態 | ID / URL | 時刻 |
  | release PR | 未 | | |
  | <provider type> ... | 未 | | |
  ## チェックリスト
  <.pipeline/checklist.md>
  ```
  以降の更新は `$GH api -X PATCH $R/issues/<n> -F body=@.pipeline/release-issue.md`

## 4. リリースノート (下書き → オーナー清書 → 英訳 → render 検証)

- `bash $KIT/scripts/release_notes.sh ensure $NEW` (無ければ draft) → `$NOTES/$NEW.md` を PREV..TARGET のマージ PR の「変更点」で肉付け
- **オーナーに提示して待つ** (待つ前に下書きを issue 本文の「ノート (下書き)」節に保存)。返ってきた文面をそのまま保存
- `release_notes.sh en-ensure $NEW` → 英訳を軽く確認 → `release_notes.sh render $NEW` (provider の `notes_limits` で文字数検証)。超過は直して再提示
- notes_dir が無いプロジェクト (`release.notes_dir` が空) はこの手順をスキップ

## 5. release PR → squash マージ

- `git add <version ファイル> $NOTES/` → `git commit -m "chore(release): bump version to $NEW"` → push
- MCP `create_pull_request` (base main、head `release/v$NEW`、title `chore(release): v$NEW`、body = ノート要約 + `Refs #<release issue>`)
- MCP `merge_pull_request` (squash、expectedHeadSha)。`RELEASE_SHA=$(git rev-parse origin/main)` を issue に記録。**タグはここでは作らない** (provider に任せる)

## 6. 配信 (providers を順に)

各 `[[release.providers]]` について (index を `PROVIDER_INDEX` で渡す):

```bash
PROVIDER_INDEX=<i> bash $KIT/scripts/providers/<type>.sh deploy "$NEW" "$RELEASE_SHA"      # ID=... URL=... を返す
PROVIDER_INDEX=<i> bash $KIT/scripts/providers/<type>.sh status "<ID>"                    # STATUS=running|finished|failed
```

- `supabase-mcp` は `$KIT/scripts/providers/supabase-mcp.md` の手順 (承認バンドル → オーナーの「適用して <8桁>」→ MCP `apply_migration`)
- CLAUDE.md `## release` 節に provider に無い手順があれば、その記述に従う (`shell` provider で表現できるならそちらへ)
- 結果 (ID / URL / 時刻 / 状態) を issue の「配信状態」に記録。失敗した provider は「失敗」と記録し、同じ版で再実行しない
  (再実行は `/pipeline:release patch` で版を上げて手順 3 から)
- main にマージされる web / DB の変更は後方互換 (既存バイナリが動き続ける) が前提。破壊的ならオーナーに確認してから

## 7. 配信完了と実機確認

- 全 provider の完了を issue に記録し、オーナーにチェックリスト (手順 2) を提示して待つ (待つ前に issue 本文を最新にする)
- 結果 (例: 「#27 OK / #28 NG (Android): 決定ボタンが反応しない」) を処理:
  - OK → `$GH api -X PATCH $R/issues/<n> -f state=closed` + `$GH label-del <n> <merged_unverified>`
  - NG → オーナーの言葉をそのまま本文にし、再現条件・対象版・OS を付けた修正 issue を ready で作成 (元 issue にリンク。元 issue は open のまま)
- 全 provider 成功ならリリース issue を close。失敗があれば open のまま (次回の PREV 判定のため)
- 本番昇格 (ストアの製品版 / 審査提出) は手動

## 再開

リリース issue の「配信状態」を読み、「未」の工程だけ順に実行する。`release/v$NEW` ブランチと PR が既にあればそれを使う。
