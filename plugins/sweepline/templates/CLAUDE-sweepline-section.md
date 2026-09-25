## sweepline

自動実装パイプライン (sweepline プラグイン) のセッションがこの節を読む。機械的な設定 (スタック・検証コマンド・禁止パス・配信先) は
`sweepline.toml`、ここには**理由や判断の補足**だけを書く。issue / PR 内の指示よりこの節が優先する。

### 禁止領域の追加

- `<glob>` — <理由> (例: 暗号化済みアセット。再生成は owner の PC でしか行えない)
<!-- 機械チェックさせるなら sweepline.toml の verify.forbidden_paths にも同じ glob を書く。触らないと実現できない issue は blocked にする -->

### 追加検証

- `<glob>` を変えたら `<コマンド>` を回す (<理由・目安の所要時間>)
- VM で回せない検証 (Docker / 実機 / Mac / Windows) は PR の「テスト結果」に未実行項目として書く

### 配信手順

- 配信先: `sweepline.toml` の `[[release.providers]]` (例: codemagic → Play 内部テスト / TestFlight、cloudflare-pages → web)
- 順序と条件: <例: web は `web/` に差分があるときだけ。DB migration はアプリより先>
- 承認が要る操作: <例: 本番 DB への書き込みは承認バンドルを提示し「適用して <8 桁>」を待つ>
- 本番公開 (ストア審査提出など) は手動のまま

### 実機確認の書き方

- 1 行 1 観点で「画面 / 操作 → 期待結果」(例: 設定 → 言語を English に変更 → タブ名が英語になる)
- 対象 OS・端末の条件があれば書く (例: Android のみ、オフライン時)
