---
name: req
description: オーナーの一言から対話で要件を固め、テンプレ準拠の GitHub issue を作る (完了条件・実機確認の観点まで)。「OK」で着手ラベル (pv:ready) を付け、次の sweep が着手する。ローカル / クラウドどちらでも動く
---

# /pipeline:req <一言>

思いつき (例: 「設定画面にダークモード切替を足したい」) を、パイプラインが着手できる issue に落とす。GitHub 操作は REST (`gh.sh`)。

```bash
KIT="${CLAUDE_PLUGIN_ROOT:-}"; [ -d "$KIT/scripts" ] || KIT=/opt/pipeline/kit/plugins/pipeline
[ -d "$KIT/scripts" ] || KIT="$(dirname "$(dirname "$(find ~/.claude/plugins -path '*pipeline/scripts/pipeline_config.py' 2>/dev/null | head -1)")")"
PC="python3 $KIT/scripts/pipeline_config.py"; GH="bash $KIT/scripts/gh.sh"
SLUG="$($PC repo)"; READY="$($PC labels | python3 -c 'import json,sys; print(json.load(sys.stdin)["ready"])')"
```

## 手順

1. **現状を読む**: 関連コード、既存 issue (`$GH api "repos/$SLUG/issues?state=open&per_page=100" --jq '.[] | "\(.number) \(.title)"'`)、
   直近のリリースノート (`release.notes_dir`)。一言の用語をコードの語彙 (画面名・クラス名) に対応付ける
2. **質問は 1 回にまとめる**: 対象 / 完了条件 / やらないこと / 実機確認の観点 の 4 点について推奨案を添えて 1 通で聞く。答えが無い項目は推奨案で埋める
3. **分割**: 1 issue = 1 タスク。大きければ分割案 (順序と `Depends on: #N`) を提示して選んでもらう
4. **本文を生成**: `$KIT/templates/issue-body.md` の構成 (やりたいこと / 完了条件 (チェックボックス) / 対象領域 / 対象ファイル・関連コード / 背景・現状 / 実機確認の観点 / 混ぜないこと)。
   禁止領域 (`$PC forbidden` と CLAUDE.md `## pipeline`) に触る要件なら、その旨とオーナー作業の切り出しを本文に書く
5. **重複検索**: 似た issue があれば提示 (統合するか `Related: #N`)
6. **最終提示**: 本文全文と次の文言:
   > この「OK」で `<READY>` が付き、次の sweep (`sweep.cron`、UTC) が着手します。待たせるなら「作成だけ」と答えてください
   - 「OK」→ `$GH issue-create --title "<title>" --body-file .pipeline/issue-new.md --label "$READY"`
   - 「作成だけ」→ ラベル無しで作成
   - 修正指示 → 直して再提示 (1 回にまとめる)
7. ローカルなら「今すぐ回しますか (`/pipeline:run N`)」と 1 回だけ尋ねる。無回答なら何もしない

## 書き方の規約

- 完了条件は「〜すると〜が表示される / 保存される」の観測可能な形
- 「実機確認の観点」はオーナーが 1 分以内に再現できる粒度 (画面 → 操作 → 期待)。`/pipeline:release` のチェックリストにそのまま載る
- 本文に実装方法は書かない (計画は impl が立てる)。「対象ファイル」は書いてよい
- タイトルは 40 字以内、動詞で終える
