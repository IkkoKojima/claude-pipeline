---
name: setup
description: 自動実装パイプラインをこのリポジトリに導入・更新する対話ウィザード (ローカルで実行)。スタック検出 → sweepline.toml → クラウド環境 (API で作成/更新) → routine (RemoteTrigger) → ラベル / 固定 issue → 疎通 run → 貼り付け案内。引数: --update (kit 更新のみ) / --deploy (配信の設定) / --check (確認だけ)
---

# /sweepline:setup [--update | --deploy | --check]

オーナーが**ローカルの Claude Code** で対象リポジトリを開いて実行する。クラウドセッションでは動かない (環境 API と RemoteTrigger は
ローカルの OAuth が要る)。質問は最小限で、推奨案を示して確認を取る形にする。**シークレットは受け取らない** (貼り付け先の案内だけ)。

```bash
KIT="${CLAUDE_PLUGIN_ROOT:-}"; [ -d "$KIT/scripts" ] || KIT=/opt/sweepline/kit/plugins/sweepline
[ -d "$KIT/scripts" ] || KIT="$(ls -d ~/.claude/plugins/marketplaces/*/plugins/sweepline 2>/dev/null | head -1)"   # marketplace clone (marketplace update で最新になる) を優先
[ -d "$KIT/scripts" ] || KIT="$(dirname "$(dirname "$(find ~/.claude/plugins -path '*sweepline*' -path '*/scripts/sweepline_config.py' 2>/dev/null | head -1)")")"
PC="python3 $KIT/scripts/sweepline_config.py"; EA="python3 $KIT/scripts/env_api.py"; GH="bash $KIT/scripts/gh.sh"
mkdir -p .sweepline; grep -qE '^\.sweepline/?$' .gitignore 2>/dev/null || printf '.sweepline/\n' >> .gitignore   # 作業ディレクトリ (ログ・生成物) は ignore
```

前提: **オーナーの対話セッション**で実行する (routine の作成に使う `RemoteTrigger` ツールはサブエージェントや非対話実行には無い)。

## 0. preflight

```bash
git rev-parse --show-toplevel && git remote get-url origin        # GitHub の repo であること
gh auth status 2>&1 | head -3                                        # gh がログイン済み
$EA whoami                                                           # claude.ai (Max/Pro) の OAuth。API キー認証では不可
$EA repo-access "$($PC repo)"                                        # 200 なら クラウドから clone 可
```

- `repo-access` が 404 → **「`/web-setup` を実行して確認の Enter を押してください」と 1 回だけ頼み**、済んだら再確認する
  (gh のトークンをアカウントに登録する公式コマンド。以後この gh が見える全 repo が使える。自分で代わりに送らない)
- `--check` ならここまでの結果と、現在の `sweepline.toml` / 環境 / routine の状態 (下の 2〜4 の照会部分) を表示して終わる

## 1. sweepline.toml

```bash
$PC detect                      # 検出結果 (name/path の配列)
[ -f sweepline.toml ] || $PC init --stacks "<name:path,...>"   # 検出結果を既定に。ユーザーに確認してから
$PC validate
```

- 検出結果を表示し「このスタック構成でよいか」を 1 回だけ確認 (複数スタックはそのまま複数 `[[stacks]]`)。
  `deno` は `supabase/functions` があるだけで検出されるので、要らなければ外す
- **既存 CI (`.github/workflows/*.yml`) があれば読んで揃える**: apt 依存 → `env.extra_apt`、テストコマンド → 各 stack の `verify_always`、集約 check 名 → `merge.wait_for_checks`。
  preset は一般解なので、CI と違うコマンドで通すのは避ける (通らない検証で sweep が止まる)
- 既にあれば触らない (`--update` でも変えない)。`kit` は手順 2 で書く

## 2. クラウド環境 (API)

```bash
KIT_SHA="$(git -C "$KIT/../.." rev-parse HEAD 2>/dev/null || cat "$KIT/../../.sha" 2>/dev/null)"   # プラグインの版
[ -n "$KIT_SHA" ] || KIT_SHA="$(gh api repos/IkkoKojima/sweepline/commits/main --jq .sha)"
NAME="$($PC get env.name)"; HOSTS="$($PC hosts | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)))')"
$EA render --kit-sha "$KIT_SHA" > .sweepline/init_script.sh && wc -l .sweepline/init_script.sh
$EA get "$NAME" || echo "new"
```

- 無ければ**作成**、あれば `kit` が変わったときだけ**更新** (`--update` は常に更新):
  ```bash
  VARS=$($PC get env.vars | python3 -c 'import json,sys; print(" ".join(f"--var {k}={v}" for k,v in json.load(sys.stdin).items()))')
  ENV_ID=$($EA ensure --name "$NAME" --init-script .sweepline/init_script.sh --hosts "$HOSTS" $VARS --description "sweepline: $($PC repo)")
  ```
- 生成した setup script はユーザーに要約を見せる (Flutter 版、Android、apt、kit sha)。5 分制約があるので重い追加には注意
- `sweepline.toml` の `kit = "<sha>"` を書き換える (これが唯一の setup による設定変更)
- **API credentials は API で登録できない**。`OPENAI_API_KEY` (任意。無ければ計画レビューは Fable 代替) は手順 7 で案内する
- API が失敗したら (400/5xx): `.sweepline/init_script.sh` の内容・ホスト一覧・環境変数を表示して「claude.ai/code の環境ダイアログに貼ってください」に落とす

## 3. routine (RemoteTrigger)

```bash
python3 $KIT/scripts/routine_body.py create --env-id "$ENV_ID" > .sweepline/routine.json
```

- `ToolSearch select:RemoteTrigger` でツールを読み込み、`{action:"list"}` で `name` が `<repo> sweep` の routine を探す。
  **ツールが無い場合** (サブエージェント / 非対話): `python3 $KIT/scripts/routine_api.py ensure --body .sweepline/routine.json` (同じ OAuth で作成 + コネクタ解除。id を返す)。
  それも失敗したら `.sweepline/routine.json` の内容と「claude.ai/code/routines で New routine → 同じ内容 (name / repo / 環境 / model / prompt / cron、Connectors はすべて外す) を入力」を案内して手順 4 へ進む
- 無ければ `{action:"create", body:<.sweepline/routine.json の内容>}` → 続けて **必ず** `{action:"update", trigger_id, body:{"clear_mcp_connections":true}}`
  (省略すると全コネクタが付く)。あれば `routine_body.py update-prompt --env-id` の body で `update` (環境や prompt の追従) + `clear_mcp_connections`
- 応答の `mcp_connections` が `[]`、`job_config.ccr.environment_id` が `$ENV_ID`、`enabled: true` を確認して trigger id を控える
- routine の 1 日の実行上限はアカウント単位 (Max 15)。`list` の件数 × 2 + 手動 run が 12 を超えるなら警告する

## 4. GitHub のラベルと固定 issue

```bash
$GH api "repos/$($PC repo)/labels?per_page=100" --jq '.[] | "\(.name)\t\(.description)"'   # 既存ラベルを先に見る
$GH ensure-labels
$GH status-issue          # 無ければ作る。番号を表示
```

- **既存ラベルとの衝突**: 既定名 (`pv:ready` など) と同名のラベルが**別の意味**で使われている (説明が違う、他の自動化が読む) なら、`sweepline.toml` の `[labels]` で
  接頭辞を変えてから `ensure-labels` する (例: `cp:ready`)。`ensure-labels` は同名があると黙って流用する
- **既存の自動化との衝突**: `.github/workflows/*.yml` に `issue_comment` / `issues` / `labeled` トリガーがあれば、パイプラインのコメント (`sweepline claim (...)`、
  計画コメント、sweep の要約) やラベル遷移に反応しないかを確認し、反応するならユーザーに知らせる (無効化するか、共存させるかはユーザーの判断)

## 5. CLAUDE.md (任意、確認してから)

`$KIT/templates/CLAUDE-sweepline-section.md` を元に `## sweepline` 節の案を提示し、ユーザーが OK したら CLAUDE.md 末尾に追記する。
禁止領域の追加・追加検証・配信手順・実機確認の書き方の 4 項目。書かなくても動く。

## 6. 疎通

- 「小さな issue を 1 つ作って今すぐ sweep を回しますか」と確認。OK なら `$GH issue-create --title "sweepline 疎通: README に導入日を追記する" --body-file <templates/issue-body.md を埋めたもの> --label <labels.ready>`
  → `RemoteTrigger {action:"run", trigger_id, body: routine_body.py run --issues N}` → 返った session URL を表示
- `sweepline.toml` / `.gitignore` / (あれば) CLAUDE.md の変更をコミットして **main に入れる** (直接 push できなければ PR → マージ。既存 CI があればその完了を待つ)。
  クラウドは main を clone するので、**main に入る前に run しない**

## 7. 貼り付け案内 (最後に必ず表示)

| 何を | どこに | 必須か |
|---|---|---|
| `OPENAI_API_KEY` (Codex 計画レビュー) | claude.ai/code → 環境 `<NAME>` → API credentials (host `api.openai.com`) と、環境変数 `OPENAI_API_KEY=placeholder` | 任意 |
| 配信の資格 | `--deploy` で案内 | 配信を使うとき |

## `--update`

手順 2 だけを**この repo の環境 (`env.name`)** に対して行う (kit sha を最新にし init_script を再生成)。他の repo の環境は各 repo で実行する (init_script は repo の設定から作るため)。routine は触らない。`sweepline.toml` の `kit` を更新して commit。

## `--deploy`

1. `sweepline.toml` の `[[release.providers]]` を確認 (無ければ候補を提示: codemagic / vercel / cloudflare-pages / supabase-mcp / actions-dispatch / shell)
2. deploy 環境 `sweepline-deploy-<stacks>` を手順 2 と同様に作る (env.vars に `SWEEPLINE_ENV=deploy` と provider が要る変数を追加)
3. 各 provider の `bash $KIT/scripts/providers/<type>.sh preflight` と `secrets_list` を実行し、貼るべき値と場所を一覧にする
4. Codemagic なら app が無いとき `POST /apps` で作る (API token は環境変数 `CODEMAGIC_API_TOKEN`。無ければ案内のみ)

## やってはいけないこと

シークレットの値を受け取る・表示する / OAuth トークンを表示する / `/web-setup` を代行する (キー送信や API 直叩き) / ユーザー確認なしに CLAUDE.md を書き換える /
既存の `sweepline.toml` を上書きする
