# provider `supabase-mcp` — Supabase 本番への migration / Edge Function 配信 (承認バンドル方式)

スクリプトではなく **`/sweepline:release` のセッション本体が読んで従う手順**。本番 DB への書き込みは MCP ツール
(Supabase コネクタ) 経由でしか行わず、**owner が承認バンドルのハッシュ付きで「適用して <8 桁>」と答えたときだけ**実行する。
Postgres への直接続はクラウドの proxy が raw TCP を通さないため使えない。

```toml
[[release.providers]]
type = "supabase-mcp"
project_ref = "abcdefghijklmnopqrst"   # 省略時は環境変数 SUPABASE_PROJECT_REF
# migrations_dir = "supabase/migrations"  # 既定
# functions_dir = "supabase/functions"    # 既定
```

## インターフェースとの対応

| 関数 | この provider での扱い |
|---|---|
| `preflight` | セッションに Supabase コネクタ (MCP) がある。MCP `get_project` (id = project_ref) が通る。`list_migrations` が読める。無ければ「migration は owner の PC から」に切り替えて止まる |
| `deploy <version> <sha>` | 下の手順 1〜5 (承認まで待つ) |
| `status <id>` | 同期処理。`list_migrations` に適用分が載っていれば `finished`、途中で止めたら `failed` |
| `secrets_list` | `Supabase コネクタ|mcp:supabase|/release のセッション作成時に有効化 (claude.ai のコネクタ設定)` / 関数を CLI で配るなら `SUPABASE_ACCESS_TOKEN|env_credential:api.supabase.com|project スコープの PAT (環境変数は sbp_ + 40 桁の 0 の placeholder)` |
| `notes_limits` | なし |

## 手順

前提: `TARGET` (リリース対象 SHA) と `PREV` (前回成功版) が決まっている。`PREV..RELEASE_SHA` に `supabase/` の差分が無ければ何もしない。

1. **未適用 migration の特定** — MCP `list_migrations` (project_id = project_ref) で本番の `version` と `name` を取り、
   `<migrations_dir>/<version>_<name>.sql` と突き合わせる。MCP `apply_migration` で適用した分は version が**適用時刻**になり
   ファイル名の version と一致しないため、**version か name (`<version>_<name>`) のどちらかが一致すれば適用済み**とみなす。
   未適用ファイルをファイル名順に列挙する (dry-run 相当)。
2. **関数の差分** — `git diff --name-only $PREV $RELEASE_SHA -- <functions_dir> supabase/config.toml` から変更のあった関数を列挙する。
   `_shared/` か `config.toml` が変わっていれば全関数。削除された関数は列挙だけ (削除は owner の明示指示でのみ)。
3. **承認バンドル** — `.sweepline/supabase-bundle.md` を 1 ファイルにまとめる:
   - project ref / RELEASE_SHA / 本番の適用済み migration の末尾 3 件 (version と name)
   - 未適用 migration の一覧と**本文そのまま** (コードブロック)
   - 配る関数 / 削除された関数 (配らない)
   - ローカルスタックでの検証結果 (`supabase start` → `supabase db reset` を回せたか。回せなければ「未実行」)
   - 後方互換の確認 (既存のアプリ・関数が動き続けるか。追加のみ / 入出力互換)。破壊的変更なら理由と移行手順
4. **提示** — `sha256sum .sweepline/supabase-bundle.md | cut -c1-8` を添えてバンドル全文を owner に見せ、
   「このバンドルを適用してよいですか。よければ『適用して <8 桁>』と返してください」と尋ねる。**待つ前に**リリース issue の本文を更新する。
   返答の 8 桁が現在のバンドルのハッシュと一致しないとき (バンドルを作り直した後の古い承認など) は適用しない。
5. **適用** (承認が一致したときだけ):
   1. 未適用 migration をファイル名順に 1 件ずつ MCP `apply_migration` (project_id、name = `<version>_<name>`、query = ファイル本文)。
      失敗したらその場で止めて報告する (残りは適用しない)。適用後に `list_migrations` で件数と name が増えたことを確認する
   2. 関数: CLI があれば `supabase functions deploy "$FN" --project-ref "$PROJECT_REF"` (verify_jwt は config.toml から読まれる)、
      無ければ MCP `deploy_edge_function`。終わったら `supabase functions list --project-ref ...` か MCP `list_edge_functions` で確認
   3. 結果 (適用した migration、配った関数とバージョン、失敗箇所) をリリース issue の「配信状態」に記録する

## やってはいけないこと

- 承認 (「適用して <8 桁>」) なしの `apply_migration` / `deploy_edge_function` / `execute_sql` の書き込み
- `execute_sql` で DDL や DML を流す (migration は必ず `apply_migration`。`execute_sql` は SELECT の確認だけ)
- バンドル内容を変えた後に古い承認で適用する (内容が変わったら再提示)
- 関数の削除、ポリシー・設定の変更をバンドル外で行う
