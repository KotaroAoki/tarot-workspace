# オーケストレーターの Windows Server 2025 移行 + インターネット公開

作成: 2026-09-28 / 状態: Phase 1・2 完了 (Mac 上で検証済み)

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

## Phase 3 — Windows Server の構築 (手順書を作成)
- [ ] 改名、固定 IP、Windows Update の再起動時間帯の制御 (ワーカーで同時脱落の事故あり)
- [ ] Python 3.11 x64、git (`core.autocrlf=false`)、clone、venv
- [ ] サービス化 (WinSW または NSSM)。停止時に graceful shutdown を待つ設定にする
- [ ] リバースプロキシ (Caddy または IIS+ARR): TLS、SSE のバッファリング無効化、数 GB のアップロード許可、長いタイムアウト、実 IP の転送
- [ ] Windows ファイアウォール: 受信は 443 のみ (8000 は外に開けない)
- [ ] ワーカー用の秘密鍵を配置し、NTFS の ACL でサービスアカウントのみ読めるようにする

## Phase 4 — データ移行
- [ ] `tarot.db` (アカウント / グループ / ワーカー / ジョブ履歴 / 表示名 / メタデータ)
- [ ] ワーカー用の SSH 秘密鍵、env ファイル
- [ ] ワーカー側で新サーバーの IP からの SSH を許可 (forwarder / sshd の許可リスト)

## Phase 5 — 並行検証
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
