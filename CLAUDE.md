# TAROT-Analyzer プロジェクト ナレッジベース

## プロジェクト概要
Snakemake ベースの抗菌薬耐性ゲノム解析パイプライン (QUAST, Mash+KmerFinder, MLST, ABRicate, ResFinder+PointFinder, PlasmidFinder, AMRFinderPlus, SeqSero2, chewBBACA cgMLST) に GUI (FastAPI + React) を付与。計算はリモート WSL2 Linux サーバーで SSH 経由実行。SeqSero2 と chewBBACA は Salmonella と判定されたサンプルのみ自動実行。

## アーキテクチャ
- **バックエンド**: FastAPI (Python 3.11) — `tarot-analyzer/api/`
- **フロントエンド**: React + Vite + TypeScript — `tarot-analyzer/frontend/`
- **認証**: SSH クレデンシャルによるセッション認証 (トークンベース)
- **ファイル転送**: SFTP (asyncssh)
- **リアルタイムログ**: Server-Sent Events (SSE)

## サーバー情報
- **開発 Mac**: API=localhost:8000, Frontend=localhost:3000
- **WSL2 サーバー**: IP=172.20.17.98, Port=2222, User=mbuser
- **conda 環境**: `py39` — snakemake および全解析ツールはここにインストール済み
- **リモートプロジェクトルート**: `/mnt/c/ftproot/tarot-pipeline`

## 開発サーバー起動方法
```bash
# API サーバー (ポート 8000)
cd /Volumes/ftproot/TAROT-analyzer/tarot-analyzer
/Library/Frameworks/Python.framework/Versions/3.11/bin/uvicorn api.main:app --host 0.0.0.0 --port 8000 --reload --reload-dir /Volumes/ftproot/TAROT-analyzer/tarot-analyzer/api --app-dir /Volumes/ftproot/TAROT-analyzer/tarot-analyzer

# フロントエンド (ポート 3000)
cd /Volumes/ftproot/TAROT-analyzer/tarot-analyzer/frontend
npm run dev
```

## 重要な技術的知見 (トラブルシューティング履歴)

### 1. SSH 非対話シェルでの conda/snakemake PATH 問題
**症状**: `bash: snakemake: command not found` または `bash: conda: command not found`
**原因**: SSH 非対話シェルでは `.bashrc` が読み込まれない。さらに `.bashrc` には非対話シェルガード (`case $- in *i*) ;; *) return;; esac`) があるため、`source ~/.bashrc` しても conda init ブロックに到達しない。
**解決**: `.bashrc` に頼らず、conda の `profile.d/conda.sh` を直接 source する:
```python
conda_init = (
    "for p in /opt/mambaforge ~/mambaforge ~/miniforge3 ~/miniconda3 ~/anaconda3 /opt/conda; do "
    'if [ -f "$p/etc/profile.d/conda.sh" ]; then . "$p/etc/profile.d/conda.sh"; break; fi; '
    "done"
)
return f"bash --login -c '{conda_init} && conda activate py39 && {inner_cmd}'"
```
**該当ファイル**: `api/services/snakemake_runner.py` の `_build_remote_command()`

### 2. asyncssh 認証失敗
**症状**: SSH 接続がパスワード認証なのに失敗する
**原因**: asyncssh がデフォルトで公開鍵認証を先に試行する
**解決**:
```python
await asyncssh.connect(
    preferred_auth="password,keyboard-interactive",
    client_keys=[],  # 公開鍵認証を無効化
    known_hosts=None,  # WSL2 ローカル環境
)
```
**該当ファイル**: `api/services/ssh_manager.py` の `connect()`

### 3. asyncssh is_closed 誤検知
**症状**: 接続直後なのに `connection.is_closed` が True を返す
**原因**: WSL2 環境で asyncssh の `is_closed` が一時的に True になる場合がある
**解決**: `_get_conn()` で `is_closed` チェックを削除。実際のコマンド実行時にエラーが出れば asyncssh が処理する。
**該当ファイル**: `api/services/ssh_manager.py` の `_get_conn()`

### 4. SFTP Errno 45 (Operation not supported)
**症状**: ファイルアップロード時に `Errno 45` エラー
**原因**: `sftp.put()` がネットワークボリューム (`/Volumes/ftproot/`) 上でファイル属性保持を試行
**解決**:
- `preserve=False` を sftp.put() に指定
- ローカルステージングを `/tmp/` に変更 (ネットワークボリューム回避)
- **重要**: ネットワークボリューム上のファイルを SFTP 転送する場合は、必ず `/tmp/` にコピーしてから転送する。`preserve=False` だけでは不十分な場合がある。
**該当ファイル**: `api/services/ssh_manager.py`, `api/routers/upload.py`, `api/services/snakemake_runner.py` (`_sync_pipeline_files()`)

### 5. ログイン後のリダイレクトループ
**症状**: ログイン成功後、一瞬ページが変わりすぐログイン画面に戻る
**原因**: `GET /api/jobs` が 401 → フロントエンドがセッション削除 → ログインへリダイレクト
**解決 (3箇所)**:
1. `GET /api/jobs` の認証をオプショナルに変更 (`api/routers/jobs.py`)
2. `api.ts` の 401 ハンドラをリダイレクトではなくエラー throw に変更
3. `auth.tsx` でセッション復元を即座に行い、`/me` 検証はバックグラウンドで実行

### 6. Python/NumPy アーキテクチャ不一致
**症状**: `dlopen...numpy...incompatible architecture (have 'x86_64', need 'arm64e')`
**解決**: `pip3 install --force-reinstall numpy` で arm64 版を再インストール

### 7. Preview launch.json のパス問題
**症状**: Preview がファイルを見つけられない
**原因**: Preview は `/Volumes/ftproot/TAROT-analyzer/` (リポジトリルート) から実行されるが、コードは `tarot-analyzer/` サブディレクトリにある
**解決**: launch.json で全て絶対パスを使用

### 8. リモートに workflow/config が存在しない (Snakefile not found)
**症状**: `Error: Snakefile "/home/mbuser/tarot-analyzer/workflow/Snakefile" not found.`
**原因**: ローカル Mac にのみ `workflow/` と `config/` が存在し、リモート WSL2 サーバーには配置されていなかった
**解決**: `SnakemakeRunner.start_job()` 内でジョブ実行前に `_sync_pipeline_files()` を呼び出し、`workflow/` と `config/` を SFTP でリモートに自動同期する。ネットワークボリューム問題を回避するため `/tmp/` にステージングしてから転送。
**該当ファイル**: `api/services/snakemake_runner.py` の `_sync_pipeline_files()`, `start_job()`

### 9. ジョブ起動時の 500 エラーハンドリング不足
**症状**: `start_job()` 内の例外がキャッチされず HTTP 500 (詳細なし)
**解決**: `api/routers/jobs.py` の `create_job` エンドポイントで `start_job()` を try-except で囲み、エラー詳細をレスポンスに含める
**該当ファイル**: `api/routers/jobs.py`

### 10. Salmonella 専用モジュール (SeqSero2 / cgMLST) の条件付き実行
**背景**: Salmonella 解析には血清型タイピングと cgMLST が必要だが、他菌種では不要かつコスト高。
**方針**: rule all のターゲットを菌種に依存させると DAG が動的になりトラブルの元なので、**ルール自体は全サンプルで実行し、ルール内の shell で `species_id_merged.json` を読み Salmonella 以外なら `SKIPPED` マーカーを書いて exit** する。パーサは `SKIPPED` の存在を検知して `status=skipped` の JSON を出力する。
**該当ファイル**: `workflow/rules/stage1_seqsero2.smk`, `workflow/rules/stage1_cgmlst.smk`, `workflow/scripts/parse_seqsero2.py`, `workflow/scripts/parse_cgmlst.py`

### 11. AMRFinderPlus の organism 解決
**方針**: AMRFinderPlus は `--organism` 引数で対応菌種に特化した point mutation 検出を有効化できる (Salmonella, Escherichia など)。`config.amrfinder.organism_map` に `species_id → AMRFinderPlus organism` のマップを保持し、shell 内 Python ワンライナーで解決して `--organism` を付与。マップ外の菌種では `--organism` 無しで acquired のみ実行する。AMRFinderPlus は **全サンプル実行** (NCBI 公式 AMR バリデーション層)。
**該当ファイル**: `workflow/rules/stage1_amrfinder.smk`, `config/config.yaml` の `amrfinder.organism_map`

### 12. chewBBACA の DB 配置 (KmerFinder と同じ運用)
**方針**: chewBBACA の Salmonella Enterobase スキーム (≈3,255 loci) は数百 MB あり `_sync_pipeline_files()` での自動同期は非現実的。KmerFinder DB と同様、リモート WSL2 サーバーに**手動配置** (`/home/mbuser/dbs/chewbbaca/salmonella_enterobase_prepped`) し、`config.cgmlst.scheme_path` で指定する。`PrepExternalSchema` 済みのものを置くこと。training file (`*.trn`) も同様。
**該当ファイル**: `config/config.yaml` の `cgmlst` セクション

### 13. chewBBACA AlleleCall の入力形式
**症状/方針**: chewBBACA AlleleCall は `-i` にディレクトリを取り、その中の全 FASTA を一括処理する設計。本パイプラインはサンプルごとにルールを動かすため、`results/{sample}/cgmlst/chewbbaca_output/input/{sample}.fasta` を作って 1 ファイルだけ含むディレクトリを渡す。出力はタイムスタンプ付きサブディレクトリに作られるので、パーサは `os.walk` で `results_alleles.tsv` を再帰検索する。
**該当ファイル**: `workflow/rules/stage1_cgmlst.smk`, `workflow/scripts/parse_cgmlst.py`

### 14. `conda run -n NAME` の active env 相対解決バグ
**症状**: `EnvironmentLocationNotFound: Not a conda environment: /home/mbuser/mambaforge/envs/py39/envs/seqsero2_env`
**原因**: `_build_remote_command` (`api/services/snakemake_runner.py`) はリモートシェルで先に `conda activate py39` してからジョブを起動する。その状態で `conda run -n seqsero2_env ...` を呼ぶと、conda は **アクティブな環境配下の `envs/`** を起点に NAME を解決するため `<py39>/envs/seqsero2_env` を探しに行って失敗する (実際には `<base>/envs/seqsero2_env` にある)。`|| true` で握り潰されると下流パーサが結果ファイル不在で FAIL するだけで原因が見えない。
**解決**: ルール shell 内で **明示的に `conda deactivate` してから target env を `conda activate` するサブシェル** を使う。**重要**: Snakemake はルール shell を新しい `bash -c` プロセスで起動するため、`_build_remote_command` の親シェルで source 済みの `conda` シェル関数は継承されない (`CondaError: Run 'conda init' before 'conda activate'` が出る)。したがって **サブシェル内で `conda.sh` を再 source する必要がある**。`conda run -n` は使わない。絶対パス指定 (`conda run -p /abs/path`) は別解だが env パスをハードコードすることになる。
```bash
set +e
(
    set -euo pipefail
    # Snakemake のルール shell は新しい bash プロセスなので conda 関数を再 source
    for p in /opt/mambaforge ~/mambaforge ~/miniforge3 ~/miniconda3 ~/anaconda3 /opt/conda; do
        if [ -f "$p/etc/profile.d/conda.sh" ]; then
            . "$p/etc/profile.d/conda.sh"
            break
        fi
    done
    conda deactivate 2>/dev/null || true
    conda activate {params.conda_env}
    <tool> <args>
) 2>&1 | tee -a {log}
EXIT=${{PIPESTATUS[0]}}
set -e
```
**該当ファイル**: `workflow/rules/stage1_seqsero2.smk`, `workflow/rules/stage1_amrfinder.smk`

### 15. VirulenceFinder の species_db_map による菌種別 DB 選択
**方針**: VirulenceFinder は菌種ごとに異なる virulence DB を持つ (`stx`, `virulence_ecoli` 等)。`config.virulencefinder.species_db_map` に `species_id → DB リスト` のマップを保持し、Snakemake ルール内の `_resolve_virulencefinder_dbs()` で解決する (AMRFinderPlus の `organism_map` と同パターン)。マップ外の菌種は SKIPPED マーカーを出力。複数 DB は shell ループで順次実行し、パーサが各 DB サブディレクトリの `results_tab.tsv` を統合する。py39 環境で直接実行 (conda 切替不要)。VFDB は ABRicate 経由で別途全菌種実行 (`abricate.databases` に `vfdb` を追加済み)。
**該当ファイル**: `workflow/rules/stage1_virulencefinder.smk`, `workflow/scripts/parse_virulencefinder.py`, `config/config.yaml` の `virulencefinder` セクション

### 16. 大容量アップロードで「SFTP transfer failed: SSH connection closed」
**症状**: 8ファイル ~3GB 等の大容量を D&D アップロードすると `SFTP transfer failed: SSH connection closed` (HTTP 502) で失敗。小さいファイルでは成功する。
**原因**: SSH 接続は **1ログイン = 1本の長命接続を全処理で使い回す** 設計 (`_get_conn`)。`is_closed` チェックは外してあり、接続が死んでも検知・再接続しない。`/api/upload/directory` は (1) 全ファイルを HTTP で `/tmp` にステージング (この間 SSH はアイドル) → (2) `sftp_listdir_recursive` (例外を握り潰す) → (3) 逐次 `sftp_upload`。WSL2 は Hyper-V NAT (vEthernet) 越しで、長いアイドル/大容量転送中に TCP がリセットされやすい。従来の `keepalive_interval=30, count_max=5` (150秒許容) ではステージング中のアイドル切断を救えず、Step3 最初の `sftp_upload` で「接続切れ」が表面化していた。
**解決**:
- `_open_connection()` に keepalive を強化 (`interval=15, count_max=4` = 60秒)。
- `SessionInfo.password` に資格情報をメモリ保持 (ログ・永続化なし、`repr=False`) し、`_reconnect()` で張り直し可能に。
- `_run_with_retry(token, op)` ヘルパーを追加し、`op(conn)` 実行が接続切断 (`is_closed` or `ChannelOpenError/ConnectionError/OSError/EOFError`) で失敗したら再接続して最大2回リトライ。`sftp.put` は上書きなので冪等 = 途中切断→先頭から再送で安全。
- `sftp_upload` / `sftp_upload_dir` / `sftp_listdir_recursive` を `_run_with_retry` 経由に変更。`sftp_upload` 内の mkdir は `exec_command` ではなく同一 conn 上の `conn.run()` で実行 (再接続後も正しい conn を使う)。
**該当ファイル**: `api/services/ssh_manager.py` (`_open_connection`, `_reconnect`, `_run_with_retry`, `sftp_upload`, `sftp_upload_dir`, `sftp_listdir_recursive`)

### 17. コンティグ (FASTA) ダウンロードとシンボリックリンク切れ
**背景**: `results/{sample}/input/contigs.fasta` は `validate_fasta` が入力 FASTA へ張る**シンボリックリンク**。NAS へのアーカイブは `cp -a` なのでリンクはリンクのまま複製され、リンク先 (ワーカーの SSD スクラッチ) が撤去された後は **dangling** になる。
**方針**: ダウンロード API は候補を順に見て最初に読めるものを採用する: `input/contigs.fasta` → `assembly/long_read/contigs.fasta` → `assembly/short_read/contigs.fasta` → `assembly/contigs.fasta`。判定は `[ -r "$p" ] && [ -s "$p" ]` (リンク切れは `-r` が偽になるので自動でスキップされる)。解決は SSH 1コマンドで全サンプル分をまとめて行い、往復を避ける。一括ダウンロードは API プロセス内で ZIP を組み立てる (圧縮は `asyncio.to_thread`、上限 300 サンプル / 2 GB)。
**該当ファイル**: `api/routers/results.py` (`_CONTIG_CANDIDATES`, `_resolve_contig_paths`, `download_contigs`, `download_contigs_archive`), `frontend/src/lib/api.ts` (`downloadContigsFasta`, `downloadContigsArchive`)

### 18. サンプル ID の「編集」= 表示名エイリアス層 (物理リネームはしない)
**背景**: サンプル ID は (1) `results/{sample}/` ディレクトリ名、(2) `report/{sample}_report.json` 等のファイル名、(3) 各モジュール JSON の `sample` / `sample_name`、(4) cgSNP DB の `bam_db/{species}/{ST}/{sample}.bam` (系統樹の tip ラベルは **BAM ファイル名の stem**、`run_core_snp_phylo.py`)、(5) plasmid DB の `index.tsv` と `plasmid_uid = {sample}__{cluster}` および `by_cluster/{cid}/{uid}.fasta/.meta.json/.msh`、(6) account DB の `jobs.samples_json`、そして (7) **他サンプルの完成済みレポートに焼き込まれた参照** (cgSNP 距離行列/tree、plasmid の `db_matches` / outbreak alerts) に散らばっている。(7) は物理リネームでは後追い修正できない (その他サンプルを再解析しない限り旧名が残る)。
**方針**: 内部 ID は**不変**とし、UI と HTML エクスポートに出すラベルだけを差し替えるエイリアス層を持つ。描画時解決なので他サンプル側の参照表示も同時に更新され、可逆で DB 整合性・再解析・冪等性に一切影響しない。
- 永続化: account DB の `sample_aliases(scope, results_dir, sample, display_name, ...)`。`scope` はテナント分離キーで、アカウントセッションは `group:{group_id}`、レガシー (直接 SSH) は `legacy:{remote_project_root}`。
- API: `GET /api/results/sample_aliases`、`PUT /api/results/samples/{sample}/display_name` (body `{"display_name": str|null}`、null/空で解除)。`GET /api/results/samples` のレスポンスにも `display_names` を同梱。表示名は他サンプルの表示名/内部 ID と衝突すると 409、`/ \` と制御文字は 400、100 文字上限。
- フロント: `lib/sampleAlias.ts` がモジュールシングルトン + `useSyncExternalStore`。React 内は `useSampleAliases()`、React 外 (htmlExport) は `displayNameOf()`。**ログアウト時に `resetSampleAliases()`** を呼ぶこと (グループ跨ぎの漏れ防止、`lib/auth.tsx` の `clearSession`)。
- **内部 ID を使い続ける箇所**: 距離行列のキー、系統樹の leafOrder と `currentSample` 判定、削除/再解析 API の引数、コンティグのダウンロードファイル名、DB ブラウザ (CoreSnpDbBrowser / PlasmidDbBrowser — 実ファイル名を見る画面なので)。表示名を出すのは描画の末端だけに留める。
**該当ファイル**: `api/services/account_store.py` (`sample_aliases` テーブル + CRUD), `api/routers/results.py` (`_alias_scope`, `_validate_display_name`, 表示名エンドポイント), `frontend/src/lib/sampleAlias.ts`, `frontend/src/components/SampleRenameDialog.tsx`, および表示側 (`pages/Results.tsx`, `pages/SampleDetail.tsx`, `pages/JobDetail.tsx`, `components/CoreSnpSection.tsx`, `components/PhyloTree.tsx`, `components/MstGraph.tsx`, `components/PlasmidDistanceMap.tsx`, `components/PlasmidProfileSection.tsx`, `components/OutbreakAlertsCard.tsx`, `lib/htmlExport.ts`)

## ディレクトリ構造 (主要ファイル)
```
tarot-analyzer/
├── api/
│   ├── main.py              # FastAPI app (v0.2.0), lifespan, DI
│   ├── models/schemas.py    # Pydantic モデル
│   ├── routers/
│   │   ├── auth.py          # ログイン/ログアウト/セッション検証
│   │   ├── jobs.py          # ジョブ CRUD, SSE ログ
│   │   ├── results.py       # 解析結果取得 (SFTP)
│   │   ├── upload.py        # FASTA アップロード → SFTP 転送
│   │   └── config.py        # パイプライン設定
│   └── services/
│       ├── ssh_manager.py   # SSH/SFTP 接続管理 (asyncssh)
│       ├── snakemake_runner.py  # リモートジョブ実行管理
│       └── result_parser.py # リモート結果パース (SFTP)
├── frontend/
│   ├── src/
│   │   ├── main.tsx         # AuthProvider ラッパー
│   │   ├── App.tsx          # ルーティング, ProtectedRoute
│   │   ├── lib/
│   │   │   ├── auth.tsx     # 認証コンテキスト (sessionStorage)
│   │   │   └── api.ts       # REST API クライアント (認証付き)
│   │   ├── pages/
│   │   │   ├── Login.tsx    # ログインフォーム
│   │   │   ├── NewJob.tsx   # ジョブ作成 (D&D / パス入力)
│   │   │   ├── JobDetail.tsx
│   │   │   └── Dashboard.tsx
│   │   └── components/
│   │       └── DropZone.tsx  # ドラッグ&ドロップ FASTA アップロード
│   └── vite.config.ts       # プロキシ設定 (/api → :8000)
├── workflow/
│   ├── Snakefile            # Snakemake パイプライン定義
│   ├── rules/
│   │   ├── stage0_validation.smk
│   │   ├── stage1_quast.smk
│   │   ├── stage1_species_id.smk     # Mash + KmerFinder
│   │   ├── stage1_mlst.smk
│   │   ├── stage1_abricate.smk
│   │   ├── stage1_resfinder.smk      # ResFinder + PointFinder
│   │   ├── stage1_plasmidfinder.smk
│   │   ├── stage1_seqsero2.smk       # Salmonella 血清型 (Salmonella 限定)
│   │   ├── stage1_amrfinder.smk      # AMRFinderPlus (NCBI, 全菌種)
│   │   ├── stage1_cgmlst.smk         # chewBBACA cgMLST (Salmonella 限定)
│   │   ├── stage1_virulencefinder.smk # VirulenceFinder (菌種別 DB)
│   │   └── stage4_aggregate.smk
│   └── scripts/             # 各モジュールの parse_*.py + per_sample_report.py
└── config/
    └── config.yaml          # パイプライン設定 (seqsero2 / amrfinder / cgmlst セクション含む)
```

## 環境変数
- `TAROT_SSH_HOST`: SSH ホスト (デフォルト: 環境依存)
- `TAROT_SSH_PORT`: SSH ポート (デフォルト: 22)
- `TAROT_REMOTE_ROOT`: リモートプロジェクトルートテンプレート (デフォルト: `/mnt/c/ftproot/tarot-pipeline`)
