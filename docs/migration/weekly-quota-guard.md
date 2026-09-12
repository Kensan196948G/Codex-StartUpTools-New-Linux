# 週間利用枠による Goal 停止

## 目的と設計

週間利用枠を50％残す目安として、指定した Codex Goal の自動継続を停止する。
Goal の累計 tokenBudget とは別の制御。従来の TokenBudget 表示を週間残量として流用しない。
承認済みの Bash 操作希望に合わせて Python 3.10 以降の標準ライブラリで実装し、PowerShell や追加パッケージは不要。
既存 Goal クライアントと同じ app-server JSON-RPC を使うが、スレッド作成・再開・ターン起動はしない。

正本は本リポジトリのコード・テストと [Codex 公式 API](https://learn.chatgpt.com/docs/app-server)。
OpenViking は補助記録であり、利用枠の根拠には使わない。

## Bash からの利用

同じ Linux ユーザー・同じ CODEX_HOME・同じ Codex 認証環境を使用する。
以下はリポジトリのルートから実行する。ID は監視する会話のスレッド ID に置き換える。

```bash
# 読み取りのみ。アカウント情報や残高は表示しない。
python3 -B scripts/main/codex_weekly_guard.py --check

# 30秒間隔の監視。明示した1スレッドだけが対象。
python3 -B scripts/main/codex_weekly_guard.py --thread THREAD_ID --remaining 50

# 1回だけ確認し、必要なら停止。継続監視にはならない。
python3 -B scripts/main/codex_weekly_guard.py --thread THREAD_ID --remaining 50 --once
```

CODEX_HOME がターミナルと異なる場合は、各コマンドの先頭に
`CODEX_HOME=/home/kensan/.codex-openai` のように対象環境を明示する。
`--bucket` は既定で `codex`。異なるモデル専用枠を使う場合は対象 ID の確認が必要。
同じ Goal に監視プロセスを複数起動しない。監視中に Goal の目的を変更する場合は先に監視を終了する。

## 判定と失敗時の動作

- `account/rateLimits/read` の対象 limitId で、`windowDurationMins=10080` の窓を選ぶ。primary / secondary の位置は固定しない。
- 複数の週間窓がある場合は残量の最小値を使う。期限切れ、欠落、不正値は利用可能として扱わない。
- `100 - usedPercent <= 50` で `thread/goal/set` に `status: paused` のみ送る。objective、tokenBudget、履歴は変更しない。
- Goal とアカウントの読み取りに成功したことを監視対象の確認とし、変更後も Goal を読み戻して paused と履歴維持を確認する。
- 週間枠の欠落や取得失敗時も paused への変更を試みる。API 全体が停止している場合や Goal を識別できない場合、停止を保証せずエラー終了する。
- paused / complete / blocked / budgetLimited / usageLimited の Goal は再開せず、監視を終了する。目的の変更を検出した場合も操作を中止する。
- 既存の非対話 `Invoke-CodexGoalRun` も paused を尊重し、次のターンを送らず `goal-paused` で終了する。paused は完了ではなく再開可能な状態として保持する。
- 終了コードは正常確認・既に非activeなら0、監視失敗なら1、週間残量による停止なら2、Ctrl+Cなら130。
- Ctrl+C は監視だけを終了する。Goal を自動停止しないため、監視なしで続行するかはユーザーが判断する。
- API の生応答、Secret、アカウント ID、クレジット残高はログへ出さない。CLI は状態と必要な使用率だけ表示する。

## 保証範囲と Rollback

これは指定 Goal の「次の自動継続」を停止する仕組みであり、進行中ターンの割り込み、
別セッションの停止、アカウント全体の課金制限、OS プロセスの強制終了ではない。
ポーリング間隔・API 遅延・表示の丸め・進行中ターン・別セッションの消費によって残量50％を下回り得る。
API 自体が不通の場合も停止操作が届かない可能性がある。
厳密な50％確保が必要なら余裕のある基準を選び、他セッションも管理する。
監視対象の更新と停止はAPI上の不可分操作ではないため、監視と並行して目的を置換しない。

常駐化する場合も、監視プロセスの死活確認が必要。再起動で Goal を自動再開してはならない。
Rollback は監視を終了し、停止済み Goal を再開する場合はユーザーが状態と残量を確認して明示操作する。
Repository の DB、Secret、認証・認可、Cloudflare、課金設定への変更はない。

## 検証方法

```bash
python3 -B -m unittest discover -s tests/python -v
```

50％境界、primary / secondary、対象枠不一致、期限切れ、不正値、API障害、停止読み戻し、
目的の変更、他スレッドの保護、通信タイムアウト、過大応答、ログへの生エラー非露出を検証する。
実環境では本作業と別の検証用 Goal を作成し、残量100％の停止基準で paused への変更・
目的と会計の維持・Goal 削除を確認した。実行中ターンの割り込み成功を主張するものではない。
