---
name: sweep
description: routine が呼ぶ無人運転の入口。リリースロック → main の健全性 → 中断 issue の回収 → ready な issue を番号順に最大 sweep.max_issues 件 /pipeline:impl → 固定 issue に要約。引数 --dry-run (選択と健全性だけ報告)。routine-fire-payload の "issues: N ..." 行があればその issue だけを対象にする
---

# /pipeline:sweep [--dry-run]

無人で走る前提 (質問しない)。GitHub 操作は REST (`gh.sh`) と GitHub MCP のみ。

```bash
KIT="${CLAUDE_PLUGIN_ROOT:-}"; [ -d "$KIT/scripts" ] || KIT=/opt/pipeline/kit/plugins/pipeline
[ -d "$KIT/scripts" ] || KIT="$(dirname "$(dirname "$(find ~/.claude/plugins -path '*pipeline/scripts/pipeline_config.py' 2>/dev/null | head -1)")")"
PC="python3 $KIT/scripts/pipeline_config.py"; GH="bash $KIT/scripts/gh.sh"
SLUG="$($PC repo)"; L="$($PC labels)"; MAX="$($PC get sweep.max_issues)"; BUDGET="$($PC get sweep.hours_budget)"
STATUS="$($GH status-issue)"; T0=$(date +%s); mkdir -p .pipeline; START_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
KIT_SHA="$(cat "$(dirname "$(dirname "$KIT")")/.sha" 2>/dev/null | cut -c1-7)"
```

- ラベル名は `L` (JSON) のキー → 値で引く (`$GH label-name ready` でも可)。以下の `<ready>` などはその値
- `pipeline.toml` が無い / `validate` が NG → (a) 起動障害として固定 issue にコメントして終了 (setup 未完か、まだ main にマージされていない)

開始時刻を控え、`BUDGET` 時間を過ぎたら新しい issue に着手しない。1 run の上限は `MAX` 件。

## 0. リリースロック

`$GH pr-open-release` が 1 件でもあれば **何もせず終了** (`/pipeline:release` 進行中)。要約だけ手順 5 で残す。

## 1. main の健全性

`origin/main` を checkout し `bash $KIT/scripts/verify.sh --always` (各スタックの verify_always だけ。build_smoke は回さない)。

- `VERIFY=ok` → 手順 2
- 失敗を分類:
  - **(a) 起動障害** (ツールチェーンが無い、依存解決の失敗、hook ビルド失敗、ネットワーク / proxy エラー、setup 未完) → 修復 issue は作らない。
    固定 issue に「sweep 起動障害: <要点>」をコメントして終了
  - **(b) コードの回帰** (テストが赤) → `[main-red] <失敗テスト名>` の open issue を探し (`$GH issues-ready` の中でタイトル一致)、無ければ
    `$GH issue-create --title "[main-red] ..." --body-file ... --label <ready>` で起票 (失敗テスト、エラー要点、main の SHA)。
    **修復 issue が open の間は通常 issue を処理しない** → その issue だけを `/pipeline:impl` して終了

## 2. 回収 (中断した issue)

`$GH issues-in-progress` の各 issue について `$GH last-labeled N <in_progress>` が **6 時間より前**のものを対象:

- PR が merged なのに in_progress のまま → ラベル遷移を修復 (`merged_unverified` を付け、ready / in_progress を外す)
- open PR がある → `/pipeline:impl N` を「続きから」(PR ブランチを checkout、手順 6 の最終検証から)
- PR が無い → `/pipeline:impl N` (origin に `claude/task-N-*` があればそこから)

6 時間以内のものは他セッションが処理中とみなして触らない。

## 3. 選択と claim

- routine-fire-payload に `issues: 30 31` の行があれば、**その番号だけ**を対象にする (ready でないものはスキップして理由を報告)
- 無ければ `$GH issues-ready` (番号順)。`Depends on: #M` が open のものは後回し。回収分を含めて合計 `MAX` 件まで
- claim は `/pipeline:impl` の手順 1 (in_progress → 「着手」コメント → 10 秒後に再確認)
- `--dry-run` はここで終了する (claim しない)。コメントは手順 5 の書式 1 本だけ (先頭行に `(dry-run)` を付け、対象 = 選択した issue、回収候補、健全性を書く)

## 4. 実行

選んだ issue を順に `/pipeline:impl N` (Skill ツール `pipeline:impl`。無ければ `$KIT/skills/impl/SKILL.md` を読んで従う)。各 issue の後に `origin/main` を取り直す。

## 5. 要約 (固定 issue に 1 コメント)

```
sweep <ISO 時刻> (session: <URL or id>) kit=$KIT_SHA
- 対象: #12 #15 / 回収: #9 / 指定: (payload があれば)
- 結果: #9 merged (PR #30, 計画 1 往復, エスカレーション 0), #12 blocked (理由), #15 未着手 (時間切れ)
- main: ok (<verify の要約>) / 所要: 1h48m / Fable 代替: なし / 未解決の指摘: PR #30 M2
```

`$GH comment "$STATUS" -` で投稿する。最後に `git checkout -q "$START_BRANCH"` で元のブランチに戻す (detach のままにしない)。
