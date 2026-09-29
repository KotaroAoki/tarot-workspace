# オーケストレーターの Windows Server 2025 移行 + インターネット公開

作成: 2026-09-28 / 状態: Phase 1〜4 完了、Phase 5+6 を統合して実施中 (2026-09-29)。**Mac の API は停止したまま起動しない**

## 決定事項

| 項目 | 決定 |
|---|---|
| 移行先 | Windows Server 2025 Standard (LAN 固定 IP **172.20.17.124**) (Ryzen 5 7600 / 32 GB / C: 空き 898 GB)。現名 `WIN-36OEJUHC6C6` → 改名する |
| 配置 | 院内 LAN (ワーカーと同じ) + ルータで **443 のみ**転送 |
| 実行環境 | Windows ネイティブ Python 3.11 x64 + Windows サービス (WSL2 は使わない) |
| TLS | 組織のドメインと証明書 (情報部門から払い出し) |
| 利用者 | 院外の組織を含む → 共通の ID 基盤は使わない |
| 認証 | **アプリ内 MFA (TOTP) 必須** + ログイン試行制限・ロックアウト |
| 登録 | **申請 → 管理者承認**。承認前はログインも解析も不可。登録コードでの即時有効は廃止 |
| 管理者 | 全施設のデータを見られるので **LAN 内からのみ**ログイン可 |
| 施設間比較 (符号化施設名) | **別プロジェクト**。今回は現行のグループ完全分離を維持 |

## 構成

```
インターネット ─443→ ルータ ─→ Windows Server (院内 LAN)
                               ├ リバースプロキシ (TLS 終端)
                               │    └→ 127.0.0.1:8000
                               └ TAROT API (サービス, --reload なし)
                                    ├ ビルド済みフロントを同一オリジンで配信
                                    └─SSH→ honban / kibanb / tugrip
```

## Phase 1 — 本番化 ✅ (2026-09-28)
- [x] `api/frontend_static.py`: `TAROT_FRONTEND_DIST` を設定したときだけ dist を同一オリジンで配信。`/api`・`/health`・`/docs` 等の予約パスには index.html を返さず JSON の 404。dist の外は読ませない。MIME 型を固定 (Windows はレジストリで `.js` が `text/plain` になりうる)。`assets/` は immutable、index.html は no-cache
- [x] `api/serve.py`: 本番ランチャー。`--reload` なし・`127.0.0.1` 待ち受け・ワーカー 1・`X-Forwarded-For` はプロキシからのみ信用・graceful shutdown 上限 30 秒。**UTF-8 モードでないと起動しない** (Windows の既定 cp932 で config.yaml の日本語が読めなくなる)。`--check` で設定だけ検査
- [x] `deploy/tarot.env.example`: 設定の雛形 (実物はリポジトリの外に置く)
- [x] `TAROT_ENABLE_DOCS` / `TAROT_CORS_ORIGINS`。API の情報は `/api/info` (フロント配信時は `/` を画面に譲る)
- [x] `.gitattributes` で LF 固定 (既存ファイルの正規化差分はゼロを確認済み)
- [x] Windows で壊れる箇所: リモートパスを `PurePosixPath` に (`sftp_upload` の mkdir が `\mnt\...` になっていた)、tar の arcname を `as_posix()`、ローカルのテキスト I/O に `encoding="utf-8"`、Windows では `resource` を触らない
- [x] 検証: 空の DB・鍵なし・別ポートで本番構成を起動し、ブラウザでログイン画面 (コンソールエラー 0)、各経路のステータス・MIME・キャッシュ、パストラバーサル、停止 (1 秒) を確認。`api/tests` 89 件 pass

**Mac で本番構成を試す手順** (開発用の uvicorn --reload とは別ポートで):
```
cd tarot-analyzer/frontend && npm run build
cd .. && python3 -X utf8 -m api.serve --env-file ~/tarot/tarot.env --check
python3 -X utf8 -m api.serve --env-file ~/tarot/tarot.env
```
**注意: 本物の DB と鍵を指した本番構成を、開発用 API と同時に動かさないこと** (ディスパッチャが 2 つになり、同じワーカーへ二重投入する)。

## Phase 2 — 公開に必要な守り ✅ (2026-09-28)
`TAROT_INTERNET_FACING=true` で以下を**すべて強制**する (個別に緩められない)。詳細は CLAUDE.md #62。

**監査で見つかって塞いだ穴** (公開前に必須だったもの):
- [x] 認証すり抜け: `Authorization: Bearer honban` (ワーカー名) でログインなしに API を使えた
- [x] ワーカー上のコマンド注入: アップロードのファイル名がシェル文字列に埋め込まれていた (+ パストラバーサル)
- [x] グループ分離の破れ: `?results_dir=../../<他グループ>/results` / ジョブ ID で他グループのジョブを操作 / `GET /api/jobs`・Dorado 一覧が全グループを返していた
- [x] `/api/config` が未認証で書き換え可能 / `config_overrides` がそのままシェルへ
- [x] `/api/admin/db/candidates` が NAS 全体 (他グループの DB) を列挙していた

**入れた守り**:
- [x] 2 段階認証 (TOTP) の登録・入力・リカバリーコード・管理者によるリセット
- [x] 申請 → 管理者承認 (承認時に既存グループへ入れられる)。既存アカウントは移行で「有効」のまま
- [x] ログイン試行の制限 (ユーザー単位 5 回 / IP 単位 20 回 / 15 分)
- [x] 管理者は LAN 内のみ (LAN 外からのログインでは admin ロールを持ち込めない)
- [x] レガシーログイン無効、`/docs` 無効、`/health` は LAN 外に詳細を出さない
- [x] セッションの有効期限 (操作なし 120 分 / 最長 12 時間)
- [x] セキュリティヘッダ (HSTS・X-Frame-Options・CSP の frame-ancestors 等)
- [x] ワーカーの SSH ホスト鍵の固定 (`TAROT_WORKER_KNOWN_HOSTS`)
- [x] 入口の検証 (名前・パス・クエリ) と、ジョブ投入時の `input_dir` をグループ配下に限定
- [x] 検証: `api/tests` 147 件 pass。検証用サーバー (ワーカー接続だけ差し替え) で、申請 → 承認待ちで拒否 → 管理者の 2 段階認証登録 (QR) → 誤コード拒否 → リカバリーコード表示 → 承認 (既存グループへ) をブラウザで確認

**運用で決めること**:
- [ ] admin ロールの見直し (現在 kaoki / kaoki_bsi / kaoki_temp / Yamaguchi / Toho_omori の 5 件。これからは承認などの管理権限を意味する)
- [ ] `TAROT_TRUSTED_NETWORKS` の実際の LAN 範囲 (172.20.17.0/24 で正しいか)

**残した既知の制約**:
- セッションと実行中ジョブはメモリ上 (再起動で消える) — 従来どおり
- セッション期限切れ後も SSH 接続は保持される (実行中ジョブが参照するため。ログアウトで解放)

## Phase 3 — Windows Server の構築 (完了 2026-09-29)
手順書: `tarot-analyzer/deploy/windows/README.md`。ゴールは「空の DB で API と Caddy が起動し、
LAN 内から HTTPS のログイン画面が出る」まで。**本物の DB とワーカー鍵での起動は Phase 5/6**
(ディスパッチャの二重起動を防ぐため)。
- [x] 構成ファイル: `setup.ps1` (冪等・Windows 上で api テストも実行)、WinSW のサービス定義 2 つ、`Caddyfile`、`worker_known_hosts`
- [x] `api/requirements.txt` に漏れていた asyncssh を追加し、版を固定
- [x] `tools/manage_accounts.py` (最初の管理者の作成・ロール変更)
- [x] ホスト鍵の固定を honban で実機確認 (正しい鍵 → 接続 / 誤った鍵 → 拒否)
- [x] GitHub へ push (Windows は読み取り専用デプロイキーで clone)
- [x] Windows で README の手順 1〜10 を実施。TAROT-ORCH で TarotApi / TarotCaddy が .\tarot-svc で稼働、
  443 のみ開放、172.20.17.99 のブラウザでログイン画面の表示を確認。証明書は**仮の自己署名** (tarot-orch.lan, 90 日)
- 実施中に分かったこと (手順書に反映済み):
  - 院内の途中の機器が**送信元ポート 123 番の NTP を落とす**ため w32tm は外部に届かない → 時刻源は NAS (172.20.17.58) の NTP サーバー機能。NAS は stratum 9 (自分の時計基準) を名乗っている
  - ssh-keyscan は kibanb/tugrip のフォワーダー迂回経路の遅れで失敗する → ssh + `UserKnownHostsFile` で照合 (3 台一致)
  - kibanb/tugrip が 9/17 の再起動後、ログオン待ちでフォワーダーが起動せず **12 日間ワーカー不在**だった。自動再起動はポリシーで停止済み
- 残り (Phase 3 の外):
  - [ ] 情報部門へ申請: .124 のまま公開できるか / ドメイン名と証明書 / 443 転送の時期 / UDP 123 の許可
  - [x] kibanb/tugrip のフォワーダーをログオン無しで起動させる (AtStartup トリガー + LogonType=Password。両機とも再起動・非ログオンで復帰と 9 分後の WSL 継続を実機確認)
  - [ ] kibanb/tugrip の localhost relay が毎回失敗し NAT 迂回になっている (`relay-fallback-nat`) 件の調査
  - [ ] 管理者の作成 (`tools/manage_accounts.py create-admin`、Mac の DB に対して)
- 決定 (2026-09-28): 管理者の操作は **172.20.17.99 のみ** (`TAROT_TRUSTED_NETWORKS=172.20.17.99/32`)。
  管理 API と Dorado もこの 1 台からのみになる。172.20.17.99 には hosts でホスト名 → 172.20.17.124 を登録 (ヘアピン NAT 対策)
- 決定: 旧 admin 5 アカウント (kaoki / kaoki_bsi / kaoki_temp / Yamaguchi / Toho_omori) は user に戻した (Mac の DB に適用済み。バックアップ `api/data/tarot.db.bak-20260928_105257`)。管理者は新規作成する

## Phase 4 — データ移行 (完了 2026-09-29)
- [x] `tarot.db` を sqlite の `.backup` で書き出し USB で移送 (グループ 11 / アカウント 11 / ワーカー 3 / ジョブ 576)。DB に Mac ローカルのパスは無い。起動時、実行中・待機中だった 13 件は履歴 (中断) として復元されるだけで再投入はされない
- [x] ワーカー用の SSH 秘密鍵を `C:\TAROT\secrets\tarot_orchestrator` に配置 (tarot-svc が読める ACL。Windows の ssh は他ユーザーが読める鍵を `bad permissions` で拒むので、手動確認は管理者専用の一時コピーで行う)
- [x] 新サーバー (.124) から 3 台すべてに SSH で入れ NAS が見えることを確認 (許可リストの変更は不要だった)
- 決定: **Mac の API は止めたまま**にし、Phase 5 と 6 を統合する (二重ディスパッチの心配が無く、MFA 登録も消えない)

## Phase 5 — 検証 (Phase 6 と統合)
- [x] `TAROT_WORKER_SSH_KEY` を設定して再起動 (`Registered 3 worker(s) into SSH pool`)
- [x] tarot_admin で 172.20.17.99 からログイン → MFA 登録 → 管理画面
- [x] kaoki でログイン → MFA 登録 → Results 表示 / 小さな FASTA のジョブ 1 本が完走
- [x] 大容量アップロード (Caddy 経由) / HTML 書き出し・A4 PDF / cgSNP 再実行 / 利用申請 → 管理者承認
- [ ] Dorado (院内 pod5 フォルダ指定、172.20.17.99 から)
- [ ] 院外からの見え方 (.99 以外の端末: パス秘匿・Dorado フォルダ指定なし・管理画面 403)
- [ ] **ディスパッチャが 2 つにならないようにする**: Windows 側はテスト用ワーカー 1 台に限定するか、Mac 側を閲覧専用にする
- [ ] ログイン (MFA) → アップロード (大容量を含む) → ジョブ → SSE ログ → 結果 → cgSNP → dorado → HTML / PDF 出力
- [ ] 院外を想定した回線 (モバイル回線等) から疎通を確認

## Phase 6 — 切り替え
- [ ] 走行中のジョブが 0 の時間に、Mac の API を停止 → `tarot.db` を最終同期 → Windows 側を起動
- [ ] 利用者の URL を変更。Mac は開発用として残す

## Phase 7 — 外部公開
- [ ] DNS、証明書、ルータの 443 転送
- [ ] 外部からの脆弱性確認、アクセスログと失敗ログインの監視

## 未回答
- (なし)
