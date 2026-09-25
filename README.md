# claude-pipeline

Issue 駆動の自動実装パイプラインを **Claude Code プラグイン**として配布するリポジトリ。
GitHub Issues に `pv:ready` を付けると、Claude Code on the web のクラウドセッション (routine) が
「計画 → 計画レビュー (Codex / Fable) → 実装 (Opus) → 検証 → PR → 自動マージ」まで無人で通し、`/pipeline:release` で配信する。

設計と経緯: [pokemonitor/docs/pipeline/plugin-plan.md](https://github.com/IkkoKojima/pokemonitor/blob/main/docs/pipeline/plugin-plan.md)
(v4.2 の運用設計は同 `cloud-session-pipeline-plan.md`。pokemonitor は private なので第三者には開けない。要点はこの README にある)。

## 導入 (オーナーの作業)

一度だけ (アカウント):

```
claude plugin marketplace add IkkoKojima/claude-pipeline
claude plugin install pipeline@claude-pipeline
claude                 # 任意の repo で
/web-setup             # 確認 Enter 1 回。以後この gh が見える全 repo をクラウドが clone できる
```

リポジトリごと:

```
claude                 # 対象 repo で
/pipeline:setup        # スタック検出 → pipeline.toml → クラウド環境 (API) → routine → ラベル / 固定 issue → 疎通 run → 貼り付け案内
```

`/pipeline:setup` は**オーナーの対話セッション**で実行する (routine 作成に使う `RemoteTrigger` はサブエージェントや非対話実行には無い)。
生成した `pipeline.toml` は **main に入って初めて効く** (クラウドは main を clone する) ので、保護ブランチや CI がある repo では PR とその完了を待ってから疎通 run に進む。
既存 CI があれば、その apt 依存・テストコマンド・集約 check 名を `pipeline.toml` に揃える (setup が案内する)。

貼り付けるもの: 環境の API credentials に `OPENAI_API_KEY` (任意。無ければ計画レビューは Fable 代替)。配信を使うなら `/pipeline:setup --deploy` の案内に従う。

日常: `/pipeline:req <一言>` で issue → 定時 sweep を待つか `/pipeline:run N` → 固定 issue `#pipeline-status` の要約 → `/pipeline:release patch` → 実機確認の結果を返す。

## スキル

| スキル | どこで | 役割 |
|---|---|---|
| `/pipeline:setup` | ローカル | 導入・更新ウィザード (`--update` kit 更新 / `--deploy` 配信設定 / `--check` 確認のみ) |
| `/pipeline:req` | どこでも | 一言 → テンプレ準拠 issue |
| `/pipeline:run [N...]` | ローカル | sweep routine を今すぐ 1 回起動 |
| `/pipeline:sweep` | クラウド (routine) | 無人運転の入口 |
| `/pipeline:impl N` | クラウド | 1 issue を計画 → レビュー → 実装 → 検証 → PR → マージ |
| `/pipeline:release` | クラウド (deploy 環境) | 版上げ → ノート → release PR → providers で配信 → 実機確認 |

## pipeline.toml

repo ルートに置く唯一の設定 (`/pipeline:setup` が生成)。省略した項目は preset が補い、書いた値が常に優先する。

```toml
version = 1
kit = "<commit sha>"           # setup が書く。環境の setup script と一致

[models]
session = "fable"              # routine のモデル
implementer = "opus"           # 実装サブエージェント
plan_review = "gpt-6-astra"    # Codex。API 制限時は Fable 代替

[sweep]
max_issues = 3
cron = "0 4,16 * * *"          # UTC
hours_budget = 2

[env]                          # クラウド環境 (省略時 name = "pipeline-" + stacks 名)
name = "pipeline-flutter"
extra_hosts = []               # 既定リスト + stack のホストに追加
extra_apt = []                 # setup で apt-get install
[env.vars]
PIPELINE_ENV = "impl"

[[stacks]]                     # 複数可。path で monorepo を分ける。変更ファイルのパスで検証を選ぶ
name = "flutter"               # flutter / node / python / deno / generic
path = "."
flutter_version = "3.41.9"     # stack 固有オプション (preset の opts)
verify_always = ["flutter analyze --no-fatal-infos", "timeout 1200 flutter test"]   # 省略時は preset
[stacks.verify_paths]          # glob → 追加コマンド
"ml/**" = ["python3 -m pytest ml/tests -q"]

[labels]                       # 省略時の既定。既存ラベルと衝突するときだけ変える
ready = "pv:ready"
in_progress = "pv:in-progress"
merged_unverified = "pv:merged-unverified"
blocked = "pv:blocked"
skipped = "pv:skipped"
release = "release"

[verify]
forbidden_paths = []           # 既定 (pipeline.toml .claude/** .github/** codemagic.yaml) に追加
review_focus = []              # 計画レビューで特に見る領域
[verify.env]                   # 検証コマンドに渡すダミー値 (秘密は書かない)

[merge]
wait_for_checks = []           # 例: ["ci-ok"]。既存 CI が緑になるまで待ってから squash

[release]
version_stack = "flutter"      # 版を持つ stack
notes_dir = "release_notes"
[[release.providers]]
type = "codemagic"             # codemagic / vercel / cloudflare-pages / supabase-mcp / actions-dispatch / shell
workflows = ["android-internal", "ios-testflight"]
```

### stack preset

| name | 検出 | verify_always | build_smoke | 追加ホスト |
|---|---|---|---|---|
| flutter | `pubspec.yaml` | `flutter pub get` / `flutter analyze --no-fatal-infos` / `flutter test` | `pubspec.*` `android/**` → `flutter build apk --debug` | dl.google.com, maven.google.com |
| node | `package.json` | `npm ci` / lint / test / build (`--if-present`) | なし | nodejs.org |
| python | `pyproject.toml` / `requirements*.txt` | uv (`uv.lock` があれば) or pip → pytest | なし | astral.sh |
| deno | `deno.json` / `supabase/functions` (検出時の path は `supabase`) | `deno test -A` | なし | deno.land, dl.deno.land, jsr.io, esm.sh |
| generic | なし | なし (pipeline.toml に書く) | なし | なし |

### provider インターフェース

`scripts/providers/<type>.sh <fn>`: `preflight` / `deploy <version> <sha>` / `status <id>` / `secrets_list` / `notes_limits`。`supabase-mcp` は MCP を使う手順書。
各 `[[release.providers]]` には共通で `only_if_changed = ["glob", ...]` を書ける (PREV..RELEASE_SHA にその差分が無ければ「スキップ (差分なし)」)。`--scope type,...` は provider の type で絞る。

## 既知の制約

- `python_version` は setup (uv) にだけ効く。`uv.lock` が無い repo の検証は VM 既定の `python3` (3.11) で走る
- `release.version_stack` が無い (版が `pubspec.yaml` / `package.json` / `pyproject.toml` に無い) repo では、`/pipeline:release` の版上げは手動
- 既存の自動化 (issue コメントをコマンドとして読む workflow など) がある repo では、`/pipeline:setup` の案内に従って衝突を確認する
- routine の作成はオーナーの OAuth が要る。対話セッションでは `RemoteTrigger`、それ以外は `scripts/routine_api.py ensure`

## プラグインの更新 (作者向け)

`claude plugin update` は `plugins/pipeline/.claude-plugin/plugin.json` の `version` が上がったときだけ新しい版を取り込む。
公開する変更を main に入れたら `version` (と marketplace.json の同名項目) を必ず上げる。利用側は `claude plugin marketplace update claude-pipeline && claude plugin update pipeline@claude-pipeline`。

## 配布の仕組み

クラウド環境の setup script がこのリポジトリの pinned tarball (`codeload.github.com/.../tar.gz/<sha>`) を `/opt/pipeline/kit` に展開し、
ローカルパスの marketplace として `claude plugin install pipeline@claude-pipeline` する。セッションでは `CLAUDE_PLUGIN_ROOT` にこのプラグインが載り、
hook とスキルが有効になる。更新は `/pipeline:setup --update` (環境の setup script の sha を書き換える)。

## レイアウト

```
.claude-plugin/marketplace.json
plugins/pipeline/
  .claude-plugin/plugin.json
  skills/{setup,req,impl,sweep,release,run}/SKILL.md
  agents/{implementer,plan-reviewer}.md
  hooks/hooks.json                 SessionStart (クラウド限定)
  scripts/  pipeline_config.py  env_api.py  gh.sh  routine_body.py  verify.sh  codex_review.sh
            verify_checklist.py  pr_checks.sh  release_notes.sh  session_start.sh  providers/*.sh
  stacks/   <name>_session.sh      セッション開始時のスタック固有処理 (キャッシュ復元・依存解決)
  setup/    bootstrap.sh <stack>.sh finish.sh   環境 setup script の部品 (env_api.py render が結合)
  templates/ routine-prompt.md pr-body.md issue-body.md CLAUDE-pipeline-section.md status-issue-body.md
```
