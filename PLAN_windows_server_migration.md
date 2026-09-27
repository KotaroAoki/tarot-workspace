# オーケストレーターの Windows Server 2025 移行 + インターネット公開

作成: 2026-09-28 / 状態: Phase 1 完了 (Mac 上で検証済み・未コミット)

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

## Phase 2 — 公開に必要な守り (コード)
- [ ] **アップロードのファイル名によるパストラバーサル** (Phase 1 の作業中に発見): `upload.py` の `/api/upload` は `local_staging_dir / filename` にクライアントのファイル名をそのまま連結しており、`../` や (Windows では) `C:\...` でステージング外へ書き込める。ディレクトリアップロード側も `lstrip("/")` だけで `..` を除いていない。**公開前に最優先で塞ぐ**
- [ ] `/health` が実行中ジョブ数とセッション数を認証なしで返している → 公開時は最小限に
- [ ] レガシーログイン (任意のホストへの SSH ログイン) を env で無効化 — 公開時の既定は無効
- [ ] TOTP (RFC 6238) の登録・検証。リカバリーコードと、管理者による MFA のリセット
- [ ] ログイン試行の制限 (アカウント単位 + IP 単位)、ロックアウト、監査ログ
- [ ] 登録を申請制に変更: `accounts.status = pending/active/disabled`、管理画面で承認
- [ ] 管理者ロールのログインと管理 API は送信元が LAN の場合のみ許可 (リバースプロキシ経由の実 IP を使う)
- [ ] `/docs` と `/redoc` を本番で無効化
- [ ] セッションの有効期限 (アイドル / 絶対)。現状のセッションはメモリ上で期限なし
- [ ] セキュリティヘッダ (HSTS、CSP、X-Frame-Options 等)
- [ ] **グループ分離の監査**: 全 API について、他グループの results / DB / 表示名 / メタデータに触れられないかを確認 (前例: DB 分離が書き込み側だけだった)
- [ ] ワーカーの SSH ホスト鍵を固定 (`known_hosts=None` をやめる)

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
