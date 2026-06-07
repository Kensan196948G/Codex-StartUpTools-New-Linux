# SOURCE_OF_TRUTH

このファイルは、このリポジトリで何を正とみなすかを定義します。

## 正本となる主要ファイル

1. `PROJECT_POLICY.md`
   - このリポジトリの最上位運用方針
2. `AGENTS.md`
   - エージェントの振る舞い、実行順、成果物ルール
3. `.codex/config.toml`
   - Codex 向けのプロジェクト設定
4. `docs/migration/migration-master-plan.md`
   - 移植範囲、作業ストリーム、完了条件
5. `docs/analysis/source-inventory.md`
   - 元リポジトリに関する現時点の把握内容

## 現リポジトリ

- `/home/kensan/Projects/Codex-StartUpTools-New-Linux`
- GitHub: `Kensan196948G/Codex-StartUpTools-New-Linux`

## 元リポジトリ参照

移植元リポジトリ:

- `https://github.com/Kensan196948G/Codex-StartUpTools-New-Windows.git`

元リポジトリは参照元であり、そのまま移植先の正本ではありません。  
元と移植先に差異がある場合は、明示的な移植メモがない限り、**移植先の Codex ネイティブ方針**を優先します。

## 判断優先順位

方針や実装に矛盾がある場合は、以下の順で判断します。

1. `PROJECT_POLICY.md`
2. `AGENTS.md`
3. 検証済みの移植先実装
4. 移植先のテスト
5. 移植計画と分析ドキュメント
6. 元リポジトリの成果物

## 更新ルール

次のときにこのファイルを更新します。

- 新しいルート方針ファイルが正本に加わるとき
- 移植領域の責務や位置づけが変わるとき
- 以前の正本ファイルを廃止するとき

ルート直下に新しい方針文書を追加する場合は、必ずここに追記します。
