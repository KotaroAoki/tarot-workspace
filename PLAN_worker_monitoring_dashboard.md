# PLAN: ワーカー監視ダッシュボード (管理者向け + 利用者向け)

作成 2026-10-03 / **Phase 0〜5 実装済み (2026-10-03)・本番未反映**。Phase 6 (停滞検出・待ち時間の目安) は未着手

実装で確定した値・踏んだ点は **CLAUDE.md #74** に集約した。本ファイルは設計の意図の記録として残す。

対象: 計算ワーカー 3 台 (honban 64 コア / kibanb・tugrip 各 32 コア、いずれも Windows 上の WSL2 + GPU)。
目的は 2 つで、見せる相手と見せてよい情報が違う。

1. **管理者**: ワーカーが今動いているか、何がリソースを使っているか、いつから異常か。
2. **利用者**: 投入したらすぐ走るのか、待つのか。

## 決定事項 (2026-10-03)

| 項目 | 決定 |
|---|---|
| 履歴 | **直近 7 日を SQLite に保存**し、グラフで表示する (1 分間隔) |
| 異常の通知 | **管理者にメールで通知** (#72 の mailer を再利用、同じ異常は 1 通にまとめる) |
| 利用者向けの表示 | **ワーカー別の混み具合**。ワーカー名・状態・使用中の枠・待ち行列の長さ (うち自分のグループ分)。**他グループの検体名・グループ名・IP・パスは出さない** |
| 管理者画面からの操作 | **見るだけ**。有効・無効の切り替えは既存の管理 API (`/api/management/workers/{id}/enabled`) のまま |

---

## 1. 現状 (コードを確認した結果)

**監視の仕組みは無い。** あるのは処理の途中で行う確認だけで、どれも画面に出ていない:

| 情報 | 現在の置き場所 | 画面に出ているか |
|---|---|---|
| ワーカーごとの実行中サンプル数 | `SnakemakeRunner._worker_load` (メモリ) | ×  (Dashboard にはジョブ単位の worker_id だけ) |
| 接続失敗によるクールダウン | `_unhealthy_workers` (メモリ、120 秒) | × |
| 旧経路のジョブによる占有 | `_busy_workers` | × |
| 1 台あたりの枠 / グループの占有上限 | `samples_per_worker` (既定 2) / `account_worker_cap` (3) | × |
| Dorado の GPU スロット | `DoradoRunner._gpu_slot` (全体 2 / グループ 1) | × (待機中のジョブにだけ理由が出る) |
| SSH とディスク残量 | `DoradoRunner._preflight_workers` (Dorado 開始時だけ) | × |
| NAS の疎通 | `ssh_manager.probe_worker_nas` (ログイン時だけ) | × |

**スケジューラーの枠に数えられていない実行がある。** on-demand の cgSNP (`run_core_snp_adhoc` /
`run_core_snp_for_job`)、Bakta (`_dispatch_bakta_workers`)、プラスミド関連性
(`_run_plasmid_cluster_batch`)、Dorado は `_worker_load` を増やさない。`_worker_load` だけを見て
「空き」と出すと、実際には cgSNP の系統樹が 4 時間走っているワーカーを空いていると表示してしまう
(#37.4: 168 株の phylo は 4 時間 50 分かかった)。**Phase 0 で全種類を洗い出し、表示ではすべて数える。**

**過去の障害は、どれも監視があれば早く気づけた**:

| 障害 | 気づくのに使えた情報 |
|---|---|
| WSL VM のアイドル停止 / forwarder の受け付け停止 (#memory) | SSH 接続の成否と最終成功時刻 |
| Windows Update による 2 台同時の再起動、forwarder が起動せず 12 日不在 | Windows の LastBootUpTime と WSL の uptime |
| ホスト C: の満杯で WSL が read-only になる (**WSL 内の df は空きがあるように見える**) | `/mnt/c` の空き容量と `/proc/mounts` の ro |
| NAS 帯域の飽和で cgSNP が無言で壊れる (#26) | NAS の応答時間 |
| NanoPlot / Kaleido のハング (#27) | 実行中サンプルの経過時間と CPU 使用率 0 % |
| honban の portproxy 張り直しで接続が 5 分ごとに全部切れる (#66) | SSH 再接続の回数 |

---

## 2. 全体の構成

```
[WorkerMonitor (API 内の常駐タスク)]
   60 秒ごと / ワーカーごとに SSH 1 チャネルで probe を 1 回実行 → JSON
   5 分ごと   Windows 側の情報 (powershell.exe 経由)
        │
        ├─ メモリ上の最新値 (スナップショット)  ← 両方の API はここだけ読む
        ├─ SQLite: worker_metrics (7 日) / worker_events (状態の変化)
        └─ 通知判定 (状態機械) → mailer
   +
[スケジューラーのメモリ状態] (SSH 不要): 枠・クールダウン・実行中サンプル・待ち行列・GPU スロット

GET /api/admin/workers/*      (admin + 院内 LAN)  … 全部
GET /api/workers/availability (ログイン済み)      … 混み具合だけ (サニタイズ済み)
```

**原則**:
- **画面の表示は SSH を起こさない。** 両方の API は収集済みの値を返すだけにする。利用者向けは院外にも
  公開しているので、ページの読み込みが SSH を起こすと負荷をかける手段になる (#62)。
- **probe はスケジューラーの判定に使わない (Phase 1〜5)。** 監視の失敗が新しい失敗経路にならないように、
  `_unhealthy_workers` は従来どおりスケジューラー自身が管理する。画面には両方を並べて出す。
- **取れなかった値を 0 と表示しない** (#28 / #40)。各値は `null` + 理由を持ち、画面は「取得失敗」と出す。

---

## 3. 収集 (`api/services/worker_monitor.py`, 新規)

### 3.1 probe スクリプト (`api/services/worker_probe.py` → stdin で送る)

- **標準ライブラリのみ・Python 3.8 互換**。ワーカーの素の `python3` で動かす (honban は 3.8)。
  conda を有効にしないので速い。`fanout_core_snp_result.py` (#68) と同じ方針。
- **stdin で送る** (argv に載せると `MAX_ARG_STRLEN` の余裕が無い — #42)。
- 全体を `timeout 20` で囲む。個々の確認にも短いタイムアウトを付け、1 つが詰まっても残りは返す。
- **書き込みをしない** (read-only の検出も `/proc/mounts` で行う)。

| 項目 | 取り方 | 備考 |
|---|---|---|
| WSL の uptime | `/proc/uptime` | 前回より減っていたら再起動のイベント |
| CPU 使用率 | `/proc/stat` を 1 秒あけて 2 回 | load average と `nproc` も |
| メモリ | `/proc/meminfo` (MemTotal / MemAvailable / Swap) | |
| scratch の空き | `os.statvfs` (ワーカーごとの scratch と remote_project_root) | ext4 (#memory: drvfs→ext4 移行済み) |
| **ホスト C: の空き** | `statvfs("/mnt/c")` | **WSL 内の df では分からないのでこれを見る** |
| read-only | `/proc/mounts` の `ro` | ルートと scratch |
| NAS | `timeout 5 stat /mnt/nas/tarot` の所要時間 + マウントの有無 | CIFS の soft マウントなので応答時間が劣化の手がかり。重い読み出しはしない |
| GPU | `nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw --format=csv` (timeout 10) | GPU が無い / 失敗は `unavailable` |
| 主なプロセス | `/proc/*/cmdline` から snakemake・dorado・flye・spades・samtools・raxml 等を数え、CPU 時間の増分も見る | ハング (CPU 0 %) の検出用 |

### 3.2 Windows 側 (5 分ごと)

`/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -Command ...` で
`LastBootUpTime` と C: の空きを取る。1〜3 秒かかるので頻度を下げる。
- WSL の interop が無効なワーカーでは `unavailable` にする (推測で埋めない)。
- **interop の呼び出しは WSL VM のアイドル停止を防ぐ方向に働く** (inbound SSH は数えられないが
  interop は数えられる — memory: kibanb/tugrip の idle-shutdown)。害は無いが、挙動が変わることは記録しておく。

### 3.3 SSH の使い方

- 既存のワーカー接続プール (`get_worker_conn`) と `_channel_slot` (1 接続あたり 6 チャネル — #67) を使う。
  1 分に 1 チャネル・数秒なので、ジョブの監視ストリームや SFTP を圧迫しない。
- 接続できないときは **1 回だけ** タイムアウト付きで試し、`unreachable` と記録して次の周期まで待つ。
  監視側から再接続を繰り返さない (#67 の再接続の連鎖を作らない)。
- 状態は 4 つ: `ok` / `degraded` (一部の確認が失敗) / `unreachable` (SSH 不可) / `stale` (最後の成功から 3 周期以上)。
- **ディスパッチャーと同時に走る API は 1 つだけ** (#61)。開発用 API を本番と同時に起動すると
  監視も 2 重になる。開発環境では `TAROT_WORKER_MONITOR=0` で止められるようにする。

### 3.4 スケジューラーのスナップショット (SSH 不要)

`SnakemakeRunner` と `DoradoRunner` に読み取り専用のメソッドを足す (`worker_usage_snapshot()`)。
- ワーカーごと: 有効/無効、クールダウンの終了時刻、`_worker_load` / `samples_per_worker`、旧経路の占有。
- 実行中の作業: 種類 (通常解析 / on-demand cgSNP / Bakta / プラスミド関連性 / Dorado)、
  ジョブ ID、グループ、サンプル、`sample_phase`、開始時刻 (経過時間)。
- 待ち行列: グループごとの保留サンプル数、Dorado の GPU 待ちジョブ数。
- 実装は 1 か所に集める (#19)。管理者 API も利用者 API もこの戻り値から作る。

---

## 4. 保存 (`api/data/worker_metrics.db`, 新規ファイル)

アカウント DB (`tarot.db`) とは**別ファイル**にする。毎分の書き込みでアカウント DB のロック競合を起こさないため。
消しても運用に影響しない (履歴だけ消える)。

| テーブル | 中身 |
|---|---|
| `worker_metrics(worker_id, ts, status, cpu_pct, load1, mem_used, mem_total, scratch_free, hostc_free, nas_ms, gpu_util, gpu_mem_used, gpu_mem_total, gpu_temp, running_samples, extra_json)` | 1 分ごと。3 台 × 1,440 × 7 日 ≈ 3 万行 |
| `worker_events(ts, worker_id, kind, severity, detail, resolved_ts)` | 状態の変化だけ (不通 / 復帰 / 再起動 / read-only / 空き不足 / NAS 不通 / GPU 消失)。**保存期間は 90 日** (「いつから止まっていたか」を後から追うため) |

- 1 時間ごとに古い行を消す。グラフは 24 時間までは生値、7 日表示は 5 分平均にして返す。
- 書き込み失敗は WARNING を出して続ける (監視の不具合で API を止めない)。

---

## 5. 通知 (`api/services/worker_alerts.py`, 新規)

| 種類 | 発報の条件 (初期値・env で変更可) | 復帰の条件 |
|---|---|---|
| 不通 | `unreachable` が **5 分 (3 周期) 続いた** | 1 回成功 |
| 再起動 | WSL の uptime が減った / LastBootUpTime が変わった | (単発) |
| scratch 不足 | 空きが **50 GB** 未満 | 60 GB 以上 |
| **ホスト C: 不足** | 空きが **30 GB** 未満 | 40 GB 以上 |
| read-only | ルートか scratch が `ro` | `rw` に戻った |
| NAS | マウント無し / `stat` が 5 秒で返らない状態が 3 周期 | 1 回正常 |
| GPU 消失 | 前回まで取れていた nvidia-smi が 3 周期失敗 | 1 回成功 |
| (Phase 6 で検討) 実行中サンプルの停滞 | 対象プロセスの CPU 時間が 30 分増えない | |

- **ヒステリシスを持たせる** (発報と復帰の閾値を分ける) — 境界を行き来してメールが連発しないように。
- 同じ (ワーカー, 種類) は復帰するまで 1 通だけ。10 分以内の複数の異常は 1 通にまとめる
  (`signup_notify.py` と同じ形)。復帰したら復帰メールを送る。
- 送信先は `TAROT_WORKER_ALERT_TO` (未設定なら `TAROT_SIGNUP_NOTIFY_TO`)。
- **本文にグループ名・検体名を載せない** (外部のメールボックスに残るため — #72 と同じ)。
  ワーカー名・値・時刻・管理画面へのリンクだけ。
- 送信は `asyncio.to_thread`、失敗してもログに残して続ける。
- **API 起動直後の 1 周期目では発報しない** (再起動のたびに「不通」「再起動」が飛ぶのを防ぐ)。

---

## 6. API

### 管理者 (`require_admin` = admin ロール + 院内 LAN)
- `GET /api/admin/workers/status` — 全ワーカーの最新値 + スケジューラーのスナップショット + 未解決のイベント。
- `GET /api/admin/workers/{worker_id}/history?hours=24|168` — グラフ用。
- `GET /api/admin/workers/events?days=7` — イベント一覧。
- `GET /api/admin/workers/alert-count` — ヘッダーのバッジ用 (未解決の異常の数)。

### 利用者 (`require_session`)
- `GET /api/workers/availability` — 返すもの:
  - ワーカーごと: 表示名 (`display_name`)、状態 (`空き` / `一部使用中` / `満杯` / `停止中` / `メンテナンス中`=無効)、
    使用中の枠 / 総枠、GPU (Dorado) が使用中か。
  - 待ち行列: 全体の保留サンプル数、そのうち自分のグループの数、自分のグループの実行中サンプル数、
    Dorado の GPU 待ち数。
  - 最終確認時刻。
- **返さないもの**: ホスト名・IP・ポート・パス、他グループの名前・検体名・ジョブ ID、CPU・メモリなどの詳細値。
- テストで「応答に他グループのグループ ID・検体名・IP が含まれない」ことを縛る
  (`test_tenant_isolation_inputs.py` と同じ型)。
- 「使用中」の判定は §3.4 のとおり **スケジューラー外の実行 (on-demand cgSNP 等) も数える**。
  これらは枠の数で表せないので「使用中 (解析以外の処理)」として出す。

---

## 7. 画面

### 7.1 管理者: `/admin/workers` (新規ページ、Admin のナビから)
- ワーカーごとのカード (3 枚を横に並べ、狭い画面では縦):
  - 状態バッジ、最終確認時刻、WSL / Windows の起動からの経過時間。
  - CPU (使用率と load / コア数)、メモリ、scratch、**ホスト C:**、NAS の応答時間、GPU (使用率・VRAM・温度)。
    閾値に近い値は色を変える。取れなかった値は「取得失敗」。
  - スケジューラー: 有効/無効、クールダウン中か、枠 n / 2。
  - 実行中の作業の表 (種類・グループ・ジョブ・サンプル・フェーズ・経過時間)。ジョブ詳細へのリンク。
- 24 時間 / 7 日のグラフ (CPU・メモリ・scratch・ホスト C:・GPU・NAS 応答)。d3 の小さな折れ線。
  作るときは `dataviz` スキルに従う。
- イベントの時系列 (未解決を上に)。
- 待ち行列の内訳 (グループ別の保留サンプル数、Dorado の GPU 待ち)。管理者には院内 LAN 限定で全グループを出す。
- 30 秒ごとに再取得。
- ヘッダーの Admin に未解決の異常の数をバッジで出す (承認待ちのバッジ #72 と並べる)。

### 7.2 利用者: Dashboard の上部と New Job に「サーバーの混み具合」カード
- 行: ワーカー名 / 状態 / 枠のバー (n / 2) / GPU 使用中。下に「待ち: 全体 N 検体 (うちあなたのグループ M)」。
- 停止中のワーカーがあるときは「ワーカーの停止はあなたのジョブの失敗を意味しません。
  割り当て済みの検体は復帰後に再実行されます」と添える (不安を与えない。実際に待機列へ戻る — `_run_sample_task`)。
- New Job では送信ボタンの近くに 1 行で出す (「今投入すると待ち N 検体の後ろ」)。
- 待ち時間の見積もりは**出さない** (Phase 6 で検討)。検体の所要時間は菌種・被覆・cgSNP 群の大きさで
  10 倍以上違い (#23 / #37.4)、外れる数字を見せると誤解を生む。
- 日英の両方 (`i18n:parity` に乗せる)。

---

## 8. 段階

| Phase | 内容 | 完了の確認 |
|---|---|---|
| **0. 実機確認** | probe スクリプトを 3 台で手動実行: python3 の版、nvidia-smi の有無と出力、powershell.exe interop、`/mnt/c` の statvfs、scratch の実パス、所要時間。スケジューラー外の実行の全種類を洗い出す | 3 台分の実出力を fixture として保存 |
| **1. 収集 + 管理者 API** | `worker_monitor.py` / `worker_probe.py` / スナップショット / `GET /api/admin/workers/status` | fixture でパーサのテスト、取れない値が null になること |
| **2. 管理者画面 (現在値)** | `/admin/workers` のカードと実行中の表 | ハーネスで実 DOM を確認 (#45.6) |
| **3. 利用者向けカード** | `/api/workers/availability` + Dashboard / New Job のカード | 漏洩しないことのテスト |
| **4. 履歴とグラフ** | `worker_metrics.db`、history / events API、グラフ | 7 日分の合成データで描画と間引き |
| **5. メール通知** | 状態機械 + mailer + ヘッダーのバッジ | 状態機械のテスト (ヒステリシス・まとめ送信・起動直後は送らない)、実メール 1 通 |
| 6. (任意) | サンプルの停滞検出 (#27 型のハング)、待ち時間の目安 | 要相談 |

Phase 1〜3 で「今の状態」は見えるようになる。履歴と通知はその後に足す。

---

## 9. 注意点 (過去の事故から)

- **WSL 内の `df /` はホストの空きを反映しない** → ホスト C: は必ず `/mnt/c` で測る。
- **PGID や is_closed だけで生存を判定しない** (#36 / #42.1) → 状態は probe の実行結果で決める。
- **probe がワーカーに何かを書かない** (read-only 化したワーカーでも動く / NAS を汚さない)。
- **リモートのパスは `PurePosixPath`** で扱う (#61: オーケストレーターは Windows)。
- **改行は LF** (probe スクリプトを Windows の作業ツリーから送るため — `.gitattributes`)。
- **院外の利用者向け応答はパスを含めない** (`PathMaskingMiddleware` に頼らず、最初から入れない)。
- 監視の追加でディスパッチャーの挙動を変えない。probe の結果をスケジューラーに使うかは、
  実際の誤検知率を見てから別途決める。
- 閾値の初期値 (§5) は**実測で見直す**。Phase 4 で 1〜2 週間の履歴が溜まったら、平常時の分布を見て調整する (#38)。

## 10. 未決 (実装時に確認すること)

- 各ワーカーの GPU の型と枚数 (nvidia-smi の出力で確定)。複数枚ならカードに枚数分出す。
- scratch の実パスがワーカーごとに違うか (`scratch_root` は `~/dorado_scratch`、解析は remote_project_root 側)。
- 通知の閾値を env にするか config.yaml にするか。**config.yaml の値はワーカーのシェルに展開される経路がある** (#62)
  ので、監視の設定は API 側だけで使う env (`TAROT_WORKER_MONITOR_*`) を推奨。
