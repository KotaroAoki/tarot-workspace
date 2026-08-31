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
- **エイリアスはジョブ横断で永続する = 同じ内部 ID を再投入すると過去の表示名が復活する。** 実測 (2026-08-03): 7/29 に付けた `22173 → 22173_BSI` 等 10 件が残っていたため、8/3 に `22173/` というフォルダ名でアップロードした新ジョブが JobDetail 上で `22173_BSI` と表示され、「アップロードしたディレクトリ名がサンプル名に採用されない」ように見えた。**DB 上のサンプル名 (`jobs.samples_json`) は投入したフォルダ名どおりで、置き換わっていたのは描画だけ**。原因は JobDetail だけが内部 ID を併記していなかったこと (Results / SampleDetail は併記済み)。**エイリアスを出す画面では必ず内部 ID を併記すること。**
- **設定時の 409 衝突チェックだけでは足りない。** 「表示名 `22173_BSI`」を付けた後から、内部 ID がそのものずばり `22173_BSI` のサンプルが解析されると一覧に同名行が 2 つ並ぶ。読み出し時にも検査し、**表示名が実在サンプルの内部 ID と一致したエイリアスは自動解除**する (`api/routers/results.py` の `_resolve_aliases`、`GET /api/results/samples` と `GET /api/results/sample_aliases` の両方が経由。解除した内部 ID はレスポンスの `released` に載る)。新しく入ってきた実サンプルの名前を優先し、エイリアス側を内部 ID 表示に戻す方針。
**該当ファイル**: `api/services/account_store.py` (`sample_aliases` テーブル + CRUD), `api/routers/results.py` (`_alias_scope`, `_validate_display_name`, 表示名エンドポイント), `frontend/src/lib/sampleAlias.ts`, `frontend/src/components/SampleRenameDialog.tsx`, および表示側 (`pages/Results.tsx`, `pages/SampleDetail.tsx`, `pages/JobDetail.tsx`, `components/CoreSnpSection.tsx`, `components/PhyloTree.tsx`, `components/MstGraph.tsx`, `components/PlasmidDistanceMap.tsx`, `components/PlasmidProfileSection.tsx`, `components/OutbreakAlertsCard.tsx`, `lib/htmlExport.ts`)

### 19. contig の molecule 判定 (染色体/プラスミド) は workflow の単一の真実源で行う
**背景 (事故)**: 判定ルールが frontend の `lib/plasmidMap.ts` と workflow の `select_plasmid_contigs.py` に**手で複製**されていた (両者のコメントに「同じルールに保つこと」と明記してあったが機能しなかった)。旧ルールは 3 条件の OR カスケードで、`circularNonBackbone` と `inCircularMolecule` には backbone ガードがあったのに **`repEvidence` にだけ無かった**。MOB-suite は染色体に `rep_cluster_NNNN` (curated な Inc 型ではなく MOB 内部のクラスタ ID) を高頻度で付けるため、**最大 contig であろうと無条件にプラスミドへ昇格**していた。実測 toho_omori の **9 サンプル中 4 サンプルで染色体まるごと (6.0〜6.8 Mb) が「プラスミド ※再判定」として報告**されており、P. aeruginosa では事実上の常時発火だった。AMR 遺伝子の由来 (染色体性 vs 可動性) が逆に出る重大な誤りで、PlasAnn にも染色体が投入されていた。
**方針**: 判定は `workflow/scripts/classify_molecules.py` **のみ**が行い `molecule/molecule_classification.json` を出力する。frontend も `select_plasmid_contigs.py` もこれを読むだけ (旧ジョブ用にフォールバックは残すが、そちらにも backbone ガードを入れてある)。判定は OR ではなく **ハードガード + 重み付き証拠スコア + 3 値 (plasmid / chromosome / unclassified)**。
- **ハードガード** (発火したら証拠によらず確定): `backbone` (最大 contig) / `size_cap` (既定 600 kb 超) / `genome_budget` (昇格すると染色体側が期待ゲノムサイズの 70% を割る)。`size_cap` だけは染色体と断ぜず **`unclassified`** にする (600 kb 超のプラスミドは実在するため)。期待ゲノムサイズは `species_id` → トップレベル `genome_size_map` (アセンブリのダウンサンプリングと同じマップ = 単一の真実源)。
- **`rep_cluster_NNNN` は uncurated なので単独では不十分** (+1点、確定閾値 3.0)。curated な `IncX3` / `IncP` 等は +2。`circularity_util.split_rep_types()` が両者を分ける。
- **実測: P. aeruginosa の染色体は `IncP` + `rep_cluster_2238` + `rep_cluster_322` を持つ。** 26410_AB の閉環染色体 (6,838,261 bp / dnaA 起点 / 74×) がこの 3 つに加えて relaxase (MOBH, MOBP)・oriT・完全な MPF 一式 (MPF_F/G/T ×13) を載せていた = **組込み型 ICE**。26411 の 6.02 Mb 染色体も同じ rep_cluster ペアを持つ。低被覆で断片化した 26410 ではこの 1 領域が 3 断片に割れ、別々のメガプラスミド候補に見えていた。**菌種別の除外リストは作らないこと** — IncP-2 メガプラスミドは実在しカルバペネマーゼの主要な運び手なので、IncP を一律に無視すると本物を見逃す。backbone ガード (完全アセンブリ) とスコア閾値 (断片化アセンブリ) で既に正しく処理できている。
- **`separate_component` (染色体と別の GFA 連結成分 = +2) は環状の contig にしか与えない。** 断片化アセンブリでは全 contig が別成分になるため線状断片に credit を与えると染色体断片が大量に `unclassified` へ流れる (実測 26410 = 被覆 7〜18× の断片化アセンブリで 12 contig 中 11 本が発火し、染色体長が期待値の 0.78 倍まで痩せた)。遊離レプリコンは「閉じた環」であって「繋がらなかった断片」ではない。
- **反復 contig の高被覆は多コピープラスミドの証拠にしない** (実測 26411 の 40 kb `contig_1` は多重度 2 の反復で 90× = 染色体の 2.1 倍あるがプラスミドではない)。
**既存サンプルへの遡及**: `workflow/scripts/backfill_molecule_classification.py` (dry-run が既定、`--apply` で書き換え)。circularity.json の v2 再生成 + 判定 JSON 生成 + レポートの該当セクション差し替えを行い、**旧判定との差分だけを表示**する。**`contigs.fasta` と PlasAnn 出力は触らない** (contig 名/座標が既存の MOB/AMRFinder/Bakta 出力とズレて地図が壊れるため)。
**該当ファイル**: `workflow/scripts/classify_molecules.py` (新規), `workflow/scripts/backfill_molecule_classification.py` (新規), `workflow/scripts/circularity_util.py` (共有ヘルパー追加), `workflow/rules/stage1_mob_suite.smk` (`classify_molecules` ルール), `workflow/scripts/select_plasmid_contigs.py`, `frontend/src/lib/plasmidMap.ts`, `config/config.yaml` の `molecule_classification` セクション

### 20. `assembly_info.txt` の未使用列 (graph_path / alt_group / repeat / mult.) を活用する
**背景**: `resolve_circularity.py` は `INFO_HEADER` にこれらの列を宣言しておきながら**一度も読んでいなかった**。実測 26411 で必要になった情報は全てここに書いてあった。
**circularity.json v2 で追加**:
- **`graph_path` → `edge_map`** = edge ↔ contig の**権威ある対応表**。frontend の `buildSegmentRoles` は従来「長さ + 被覆」で推定マッチングしており、同長のセグメントが複数あると破綻していた (実測 26411: 2 kb 弱の `edge_3` と `edge_4` が両方 `contig_3` に割り当てられ同じ contig が 2 行表示。`edge_4` に対応する contig は実在しない)。`edge_map` があれば推定は一切不要。
- **`alt_group` → `alt_haplotype`** = Flye 自身が付けた代替ハプロタイプ群 ID。低被覆 (既定: 単コピー基準の 0.35 倍未満) と併せて副アレルと判定し、独立分子として数えない。実測 26411 の `contig_3` (1,509 bp / cov 11 / alt_group=2) が該当。**自前のバブル検出を書くより Flye のラベルの方が確実**。
- **`repeat` / 反復の冗長度** = 解けなかった反復は、それを挟む全 contig の**両端に重複して出力される**。実測 26411 の 40 kb `edge_1` は FASTA に 5 コピー (contig_1 単体 + contig_2 の両端 + contig_5 の両端) あるがゲノム上は 2 コピーで、**119,562 bp の水増し**。総アセンブリ長・AMR 重複計上・CheckM2 に影響する。**配列は書き換えず集計側でのみ控除する** (`redundancy.deduplicated_length`)。QUAST の Total length が水増し値のままなのは正常。
- **連結成分 (`components`)** = 遊離プラスミドは独立成分を成す。ただし #19 のとおり**ハード veto ではなく重み付き証拠**として使うこと (IS/Tn が染色体とプラスミドの双方にあると本物のプラスミドまで同じ成分に入る)。

### 21. 多重度 2 の反復による「案 1 / 案 2」の曖昧性はグラフだけでは解けない
**背景**: 実測 26411 の GFA は edge_1 (40 kb, 多重度 2, cov 90 ≒ 42+49) が edge_2 (5.94 Mb) と edge_5 (513 kb) の**両端に繋がる**構造だった。これは「バブル」(同じ入口・出口を結ぶ 2 本の代替経路) ではなく**反復配列を共有する 2 つの環状経路 = タングル**で、リンクとコピー数の制約を満たす分解が 2 通り存在する:
- **案 1**: 単一環 `edge_2 → edge_1 → edge_5 → edge_1` = 6.53 Mb の染色体
- **案 2**: 2 環 `edge_2+edge_1` (5.98 Mb) と `edge_5+edge_1` (553 kb の第二レプリコン)

**オイラー閉路でも一意にならない。** 決着させるには反復長 (40 kb) を跨ぐリードが要る。**アノテーションで確定した (2026-07-31)**: edge_5 (contig_5) に **MLST 座位 `aroE`** とリボソームタンパク質、および内在性オキサシリナーゼ `blaOXA-50` が載っていた。コア・ハウスキーピング遺伝子はプラスミド上に存在しないため **案 1 で確定**。同時に contig_6 (404 kb) は 448 CDS を持ちながら MLST 座位・リボソームタンパク質ともにゼロで、メガプラスミドであることがグラフ/replicon とは独立に裏付けられた。
**教訓**: グラフのトポロジだけでは解けない曖昧性は、**コア遺伝子の在処**で決着できる。この判定は `classify_molecules.py` の `core_gene` 証拠 (−4) として自動化済み — なお `parse_bakta.py` は名前付き CDS をアルファベット順に 100 件で切っていたため、5,565 CDS ある染色体では "a" 始まりだけで枠を使い切り **MLST 座位 `aroE` が落ちていた**。核心遺伝子は上限とは別枠で必ず残すこと (遺伝子リストは `circularity_util.core_gene_reason` に集約)。**`recA` はリストから意図的に外している** — 一部スキームの MLST 座位だが RecA ファミリーのリコンビナーゼは ICE/プラスミドに普通に載り、実測 26411 では 404 kb のメガプラスミドに `recA` が 1 個あるだけで plasmid → unclassified に退行した。加えて核心遺伝子の重みは**段階化**してある: rRNA あり / リボソーム蛋白 2 個以上 / ハウスキーピング 2 個以上 = −4、単発ヒットは −1.5 (単発では強いプラスミド証拠を覆させない) — Bakta 実行時に rRNA operon (`rrs`/`rrl`/`rrf`) / リボソームタンパク質 (`rps*`/`rpl*`/`rpm*`) / MLST ハウスキーピング遺伝子を載せる contig を染色体側へ強く倒す。**遺伝子名の完全一致で照合すること** — 部分一致にすると `rsmA` ("16S rRNA methyltransferase") のような修飾酵素まで拾ってしまい、あれは CDS でプラスミドにも載りうる。前提として #22 の contig 名復元が済んでいる必要があり、復元されていない Bakta 結果は `core_gene` の材料に使わない (誤った contig を染色体に固定するのは証拠が無いより悪い)。
**方針**: **配列は結合しない** (`synthesize_circular_contigs.py` を適用しない)。判定を誤ると実在しないキメラ配列が cgSNP 系統樹の BAM と参照配列に入り、後から追跡不能になる。分子単位では 1 つの染色体として扱い、表示は「染色体 6.53 Mb (3 contig・未解決反復 40 kb × 2 コピー)」とする。
**アセンブリ側の対策**: 40 kb の反復を解くには 40 kb 超のリードが要る。被覆抑制の `seqkit sample -p` は**長さ非依存のランダム抽出**なので (小型プラスミド保護のため意図的にそうしている)、希少な超長鎖リードも同率で捨てていた。**層化抽出** (`stratified_downsampling`, `ultralong_keep_min_len: 30000`) で 30 kb 以上を全件保持し残りだけ間引く。超長鎖だけで目標塩基数の半分を超える場合は自動的に無効化する (実質「長さ順選抜」になり小型プラスミド消失が再発するため)。

### 22. Bakta は contig 名を振り直す — parse_bakta.py で戻す
**原因**: `bakta` に `--keep-contig-headers` を渡していない。Bakta は INSDC 非準拠のヘッダ (25 文字超、`:` を含む等 — 我々の `contig_2_length:6019678_cov:42_circular` が該当) を入力順に `contig_1..N` へ振り直す。contigs.fasta は `seqkit sort -l -r` で長さ降順なので、**Bakta の番号 = 長さ順位**になる。実測 26411 では Bakta の `contig_1` が 6.02 Mb の染色体 (元の `contig_2`)、`contig_4` が 40 kb の反復 (元の `contig_1`) だった。
**影響範囲 (実測)**: `bakta_result.json` の `features[].contig` が実体と食い違う。**UI 上の誤表示は起きていなかった** — `per_sample_report._build_bakta_section` が `features` をレポートに載せておらず、feature テーブルは常に空だったため (これ自体が別の取りこぼしで、同時に修正した)。plasmidMap 系は Bakta を参照しないのでプラスミド地図は無事だった。
**解決**: `parse_bakta.py` が Bakta 自身の出力 (JSON の `sequences`、無ければ `.fna`) と入力 FASTA を**長さで突合**して名前を戻す。**Bakta の再実行は不要**。`--keep-contig-headers` は採らなかった (全サンプル再アノテーションが必要なうえ、非準拠ヘッダを Bakta が受けるか未検証のため)。
- 突合は **①出現順 + 長さの完全一致 → ②長さの一意一致** の順。どちらも成立しなければ**書き換えない** (推測で誤った名前を付けるより Bakta の名前のまま残す方が安全)。
- 元の Bakta 名は `features[].bakta_contig` に残す (生の Bakta ファイルを開いたときの照合用)。UI にも併記する。
- **冪等性に注意。** Bakta 名と元の名前は同じ `contig_N` 名前空間なので、二度当てると復元済みの名前を再度写像して壊れる (実測: 復元後の `contig_2` に再適用すると `contig_5` になる)。**名前の中身では適用済みか判定できない**ため、明示フラグ `contig_names_restored` で守っている。backfill の適用済み判定もこのフラグのみを見ること。
- 既存サンプルは `workflow/scripts/backfill_bakta_contig_names.py` (dry-run 既定)。`bakta_output/` の Bakta 生成物には触らない。
**該当ファイル**: `workflow/scripts/parse_bakta.py` (`build_contig_name_map` / `apply_contig_name_map`), `workflow/scripts/backfill_bakta_contig_names.py`, `workflow/rules/stage1_bakta.smk` (parse_bakta に contigs.fasta を input 追加), `workflow/scripts/per_sample_report.py` (`features` をレポートに載せる), `frontend/src/pages/SampleDetail.tsx`

### 23. 実行時間の内訳と高速化 — 律速は CPU コア数ではなく cgSNP
**実測 (2026-08-03, ONT long-read / kibanb 32コア)**: 1 サンプルのクリティカルパスは約 38 分で、内訳は前処理 2.5 分 → Flye+dnaapler 8 分 → **stage1 全アノテーションモジュール 1.8 分** → core_snp_map 12.8 分 → core_snp_phylo 12.6 分。**cgSNP が約 2/3**。ジョブ全体は `ceil(N/ワーカー数) × 40〜50 分`。ワーカーは honban 64 コア / kibanb・tugrip 各 32 コアで、実行中でも load15 ≈ 5・CPU 95%+ アイドル = **`cores` 既定 48 は律速ではない** (kibanb/tugrip では物理コアを超えているが、需要がそこまで届かない)。アノテーション群の最適化は投資対効果ゼロ。
**入れた高速化**:
- **`core_snp.phylo_jobs` (既定 22) と「チャンク数 = 並列数」**: この段が phylo の 9〜10 分を占める。速度を決めるのは**波数 `ceil(チャンク数 / 並列数)`** であって並列数そのものではない。**最初の実装は並列数だけ上げてチャンク数を 22 固定のまま残し、実機で全く効かなかった** — `split_genome_regions` は `chunk_size = total_len // n_chunks` (切り捨て) なので必ず端数が出て 23 チャンクになり、`ceil(23/8)=3` も `ceil(23/11)=3` も同じ 3 波。`-j 22` でも 2 波にしかならない。修正: **chunk_size を切り上げにして (厳密に n 個)、チャンク数を並列数から決める** → 常に 1 波。チャンク境界は出力に影響しない (領域ごとの mpileup を後段で連結するだけ) ことは、実参照 2 種で領域の合計被覆長が実配列長と完全一致 (2,918,010 / 4,689,117) することで確認済み。`--config core_snp_phylo_jobs=N` で上書きでき、1 ワーカー複数サンプル時はオーケストレータが頭割り値を渡す。
- **`phyml -b 100` → `-b 0`**: phyml の出力から下流が使うのは**樹形と kappa だけ** (支持率は後段の RAxML `-f a -N 1000` が付ける)。ブートストラップは樹形にも kappa にも影響しないので 100 回分は丸ごと捨てていた。
- **`core_snp.dechat_enabled` は true のまま維持すること (一度 false にして失敗した)**。「アセンブリ側で dechat を外せたなら cgSNP でも外せる」は **誤った類推**。Flye は多数の重なり合うリードから自前でコンセンサスを作るので未補正リードに耐えるが、**cgSNP の wgsim 経路は個々の生リードから擬似リードを作るだけで補正機構が無い**。実測 2026-08-03 (同一サンプル・同一 DB): 補正あり `core=2,650,434 / skipped_het=12,254 / BAM エラー率 0.10〜0.15%` → 補正なし `core=1,522,878 / skipped_het=473,265 / BAM エラー率 1.03〜2.51%`。VarScan が高エラー位置をヘテロ判定してコアから外し、**コアゲノムが参照の 88% → 52% に激減**した。169 秒/サンプルの節約と引き換えにする価値は無い。**コアゲノムは全株の共通部分なので、未補正 BAM が数本混ざるだけで解析全体が引きずられる** (補正済み 16 本の 88% が、未補正 12 本の混入で 52% に低下)。
- **未着手 (要判断)**: `bwa bwasw` は 202 秒 real / 540 秒 CPU (並列効率 2.7×) で、300 bp の wgsim 擬似リードには `bwa mem` の方が適切。dechat→wgsim→bwasw をやめて minimap2 で直接 BAM 化すれば 12.8 分 → 数分。**どちらも既存 BAM DB が bwasw 由来なので、差し替えるなら同一 species/ST の BAM 再構築と再検証が前提。**
- **`core_snp_phylo` のサンプル単位実行は意図的にそのまま**。同一 species+ST が同じジョブにあると同じ系統樹を作り直す (実測 Saureus ST8 が 3 サンプル × 12.6 分) が、連続的 cgSNP 監視ではサンプルごとにその時点の系統樹が出ることが要件。(species, ST) 単位の後追い集約にはしないこと。

### 24. ダウンサンプリングは 2 つのバグで完全に無効化されていた (全サンプル 100% のリードが Flye へ)
**症状**: 全サンプルのログが `downsample=no` かつ `Could not read Total bases, using all reads`。実測 22182 (S. aureus 2.8 Mb) が 384 Mbp = **137×** で Flye に入っていた (設計値 50〜55×)。#21 の層化ダウンサンプリングも `target_depth` も一度も発火していない。**独立した 2 件で、片方だけ直しても効かない。**
1. **NanoPlot の小数点**: `NanoStats.txt` は `Total bases:  294,624,027.0` と**小数付き**で書く。`stage1_flye_assembly.smk` の抽出はカンマ/空白しか除去しないため `.` が残り、直後の `case ''|*[!0-9]*) TOTAL_BASES=0` に落ちて「不明 = 全リード使用」になる。→ `perl` 側で `s/\..*$//` を追加。
2. **`snakemake` グローバルによる import 失敗**: `run_mash_screen.py` は末尾で**無条件に `main()` を呼んでいた**ため、`estimate_genome_size.py` の `from run_mash_screen import load_accession_map` が `NameError: name 'snakemake' is not defined` で失敗。except で握り潰されて `acc_map` が常に空になり、`_resolve_organism` が mash screen の comment 末尾にある **`[...]` (mash 自身の省略記号)** を菌種名として拾って**種名が文字列 `"..."`** になっていた。→ `if "snakemake" in globals(): main()` でガード、`_resolve_organism` は「属+種」らしいブラケットだけ採用、ローカル CSV ローダのフォールバックと空ロード時の WARNING も追加。
**教訓**: Snakemake の `script:` 用スクリプトは**必ずガード付きで `main()` を呼ぶ**こと。ガードが無いと他スクリプトから import した瞬間に落ち、`except Exception` で握り潰されて**静かに機能が消える**。

### 25. 1 ワーカー複数サンプル (samples_per_worker) — 分離すべきは「作業ディレクトリ」
**背景**: Snakemake のロックは**作業ディレクトリ単位**なので、共有 root で 2 本起動すると後発が LockException で即死する。これが `samples_per_worker=1` 固定だった理由。
**方針**: サンプル専用 workdir `{root}/orch_work/{job_id}/{sample}` で snakemake を起動し、`input_dir` / `results_dir` / `log_dir` を**絶対パスで渡して出力先は従来と同じ場所に保つ** (`{root}/{output_dir}` を前提にした監視・アーカイブ・`.status`/`.stream` の処理を一切変えない)。`samples_per_worker<=1` のときは workdir=root のままなので**従来と完全に同一のコマンドになる** (レガシーのバッチ経路と on-demand Core SNP も `single_sample=False` なので無変更)。
- `--cores` は同時サンプル数で頭割り (48 → 2 並列で 24)。`core_snp_phylo_jobs` も同様に頭割りして渡す (GNU parallel は snakemake の `--cores` 会計の外で走るため、放置するとワーカーのコア数を超える)。
- `_unlock_remote(workdir=...)` を**必ずサンプルの workdir に向ける**こと。共有 root を解錠すると同一ワーカーで走行中の別サンプルのロックを剥がす。
- **`account_worker_cap` はサンプル数ではなく「占有ワーカー台数」で判定すること** (実機で踏んだ)。既定 3 を実行中サンプル数と比べていたため、samples_per_worker=2 にしても **3 サンプルで頭打ち = 1 ワーカー 1 サンプルに逆戻り**した。samples_per_worker=1 の間は「サンプル数 = 占有台数」で一致していたので誰も気づかない。加えて **cap 到達後も既に占有しているワーカーの空き枠には積めるようにする**こと (cap=ワーカー台数の現構成では、全台を掴んだ瞬間にディスパッチが止まり 2 枠目が永久に埋まらない)。
- ディスパッチは `avail[0]` ではなく**最少負荷ワーカー**を選ぶ (先頭固定だと 1 台目を定員まで埋めてから 2 台目に移る)。
- `_sync_pipeline_files` はワーカー単位の asyncio ロックで直列化 (走行中の別サンプルが読んでいる workflow/ への同時展開を避ける)。
- 副次効果: `fastplong.html` / `reads_k21_s1.h5` のような**cwd に書かれる副産物**がサンプル別に分離される (従来は共有 root で衝突していた)。
- 残存リスク: PlasAnn の DB 自動ダウンロードはロックが無いため、**DB 未整備のワーカー**で 2 サンプルが同時に初回起動すると競合しうる (整備済みワーカーでは無害)。
- **並列度を上げると既存の read/write 競合が顕在化する。** 実機 1 本目で `bam_db/{species}/{ST}/metadata.json` の JSONDecodeError が出た (22173_BSI の phylo が失敗。BAM 自体は登録済み)。`store_bam_to_db` が `open(path,"w")` で直接上書きしており、truncate から書き終わりまでの間に読んだ側が途中の JSON を見ていた。`fcntl.flock` は **writer 同士しか**守っておらず reader (`collect_bams`) はロックを取らない。→ **一時ファイル + `os.replace` のアトミック置換**に変更し、reader 側にも再試行を追加。3 秒間の並行読み書き再現で旧 14,139 件 → 新 0 件。**NAS 上の共有 JSON を書く箇所は全て同じ形にすること。**
**該当ファイル**: `api/services/snakemake_runner.py` (`_sample_workdir`, `_build_remote_command(workdir=)`, `_unlock_remote(workdir=)`, `_try_dispatch`, `_sync_pipeline_files`), 環境変数 `TAROT_SAMPLES_PER_WORKER` (既定 2)

### 26. cgSNP は NAS 帯域が天井 — 超えると**沈黙して壊れた系統樹を出す**
**実測 (2026-08-03, samples_per_worker=3 = 9 サンプル並走)**: 9 検体中 **6 検体のコアゲノムが 0.1〜5.7%** に激減した状態で `status=completed` の系統樹・距離行列が出力された。正常値は 52〜81%。ログには `samtools mpileup: error reading from input file` が全チャンク分出ていた。
**原因**: 9 サンプル × `parallel -j 7` = 最大 63 本の同時読み出しが QNAP に集中。`/mnt/nas/tarot` は **CIFS の `soft` マウント**なのでブロックせず **I/O エラーを返す** → samtools がチャンクを放棄 → 空のまま集計。`run_core_snp_phylo.py` は空チャンク数を**表示するだけ**で、異常を検知せず completed を書いていた。**距離が実際より近く出る方向に壊れる**ため偽のアウトブレイクを示唆しかねない。
**NAS の実測帯域**: 単一ストリーム 96 MB/s、3 ワーカー同時で各 44〜54 MB/s (集約 約 150 MB/s)。**ワーカー 3 台が読むだけで飽和**する。phylo 1 回あたりの読み出しは「同一 species+ST の全 BAM」= Saureus ST8 で 28 BAM / 2.2 GB あり、**検体が増えるほど増える**。
**入れた検知 (3 段)**: ① samtools の stderr も `varscan_stderr.log` へ落とし `error reading from input file` / `[E::` / `truncated` を走査 ② 空チャンクが 1 つでもあれば失敗 ③ **コアゲノム率 < `core_snp.min_core_fraction` (既定 0.3) なら系統樹を出さず `status=failed`**。閾値の根拠は実測分布 (壊れた側 ≤5.7% / 正常側 ≥52%)。**正常値は株数が増えるほど下がる** (22 株 81% → 28 株 52%) ので、上げすぎると DB 成長で正常検体を誤検知する。
**運用**: `samples_per_worker` は **キャッシュ導入前は 2 が上限**。3 は CPU・メモリではなく NAS で破綻する。
**恒久対策 = BAM のワーカー SSD キャッシュ (`localize_bams`)**: phylo が読む「同一 species+ST の全 BAM + .bai」だけを `{remote_project_root}/bam_cache/{species}/{ST}/` に複製して、そちらを読む。
- **有効性は「サイズ + mtime 一致」で判定する。BAM は不変ではない** — 同じサンプルを再解析すると `{sample}.bam` が上書きされるので、存在チェックだけでは古い BAM を使い続ける。許容は **1 秒未満**: コピー先 (drvfs 等) の mtime 秒切り捨ては 1 秒未満に収まるので吸収でき、上書きはそれより大きくずれるので検出できる。**2 秒にすると同サイズの書き換えを取りこぼす** (検証で実証)。
- **`metadata.json` はキャッシュしない** (可変。常に NAS から読む)。
- 上限 `core_snp.bam_cache_max_gb` (既定 50) 超過で古い ST ディレクトリから削除。**使用中の ST は必ず残す**。
- 同一ワーカーで複数サンプルが同じ ST を同時に取りに来るので、ST 単位の flock + 一時ファイル + `os.replace` で直列化・原子化する。
- **失敗しても解析を止めない** (NAS の元パスにフォールバック)。キャッシュはあくまで高速化。
- 置き場所を `results_dir` 配下にしないこと (ジョブ完了時に消えて再利用できない)。
**該当ファイル**: `workflow/scripts/run_core_snp_phylo.py` (`CoreSnpQualityError`, `scan_mpileup_errors`, `reference_length`, `localize_bams`, `_cache_is_valid`, `_prune_bam_cache`), `workflow/rules/stage2_core_snp.smk`, `config/config.yaml` の `core_snp.min_core_fraction` / `bam_cache_*`
**罠**: Snakemake の `shell:` ブロックは**コメント行も format される**ため、コメント中に `{...}` を書くと `NameError: The name '...' is unknown in this context` でルールが死ぬ。

### 27. NanoPlot が Kaleido (ヘッドレスブラウザ) でハングし、サンプルが無限に止まる
**実測 (2026-08-03)**: 22188_BSI が `preprocessing` フェーズで **57 分間** 0% CPU のまま停止。`NanoPlot` プロセスと `choreographer/cli/browser_ex...` (Kaleido が起動する headless Chrome) が 10 個以上生き残っていた。NanoStats.txt と一部の PNG までは書けており、次の PNG エクスポートで固まっていた。
**性質**: flye ルールは `|| echo "NanoPlot failed, continuing"` で**失敗には耐えるがハングには耐えない** (NanoPlot にタイムアウトが無い)。ハートビートは動き続けるので API からは「処理中」に見え、ジョブが永久に終わらない。
**復旧**: `NanoPlot` の PID と `pkill -f "site-packages/choreographer"` を kill すれば `||` の分岐に落ちてそのまま先へ進む。**NanoStats.txt は先に書かれているのでダウンサンプリングは正常に働く** (kill しても被害なし)。
**恒久対策 (未実装)**: flye ルールの NanoPlot 呼び出しを `timeout` で包む。Bandage の `QT_QPA_PLATFORM=offscreen` と同種の「ヘッドレス環境に GUI 依存が紛れ込む」問題。

### 28. モジュールの「無出力」を陰性として通してはいけない — PlasmidFinder が 26/90 検体で偽陰性
**症状 (2026-08-05)**: 90 検体中 **26 検体**で PlasmidFinder が「レプリコン 0 件 / `status=PASS`」を返していたが、再実行すると**全 26 検体がレプリコンを保有**していた (0 件 → 1〜10 件)。「プラスミドが無い」ではなく「**検査できていない**」状態。裏付けとして 17559 は PlasmidFinder 0 件なのに、同じアセンブリに対し MOB-suite は閉環プラスミド 7 個を検出し `IncL/M` (76.7 kb)・`IncFIB`/`IncFII` (236.8 kb)・`ColRNAI` をタイピングしていた。
**原因は 3 段重ねで、1 つ直しても表面化しない**:
1. **Docker イメージ `plasmidfinder:latest` が honban にだけ無い** (kibanb・tugrip にはある)。**Docker Hub に存在しないローカルビルド専用イメージ**なので `docker run` が `pull access denied` で落ちる。**honban に割り当てられた検体だけが影響を受けるため、ワーカー割当次第で成否が変わり再現性が無いように見える**。DB パス (`/mnt/nas/tarot/program/plasmidfinder/plasmidfinder_db`) は NAS 共有なので 3 台とも正常。
2. ルールが `docker run ... | tee -a {log} || true` で**終了コードを捨てていた**。ログには `[plasmidfinder] Completed` と出る。
3. `parse_plasmidfinder.py` が**無条件に `status="PASS"`** を書き、出力ファイル不在をそのまま陰性として扱っていた。
**解決**: ルールは `PIPESTATUS` で docker の終了コードを見て、失敗時 (または出力が空のとき) に `PLASMIDFINDER_ERROR` マーカーを書く。**ルール自体は exit 0 のままにして下流を巻き込まない** (#cefiderocolFinder のハードフェイルでサンプル全損した件と同じ方針)。パーサは `build_result(outdir)` という純粋関数に切り出し (Snakemake と backfill の単一の真実源)、出力が 1 つも無ければ `status="FAIL"` を書く。既存検体は `workflow/scripts/backfill_plasmidfinder.py` (dry-run 既定)。
**教訓 (他モジュールにも効く)**:
- **`|| true` で外部ツールを握り潰しているルールは同じ偽陰性を抱えている。** 判定は必ず**出力ファイルの実在**で行うこと — **exit 0 でも空のことがある**ので終了コードだけでは足りない。
- **ワーカー間の Docker イメージ差分を疑うこと。** DB は NAS 共有で揃うが**イメージはローカル**。復旧は kibanb で `docker save` → NAS → honban で `docker load` (771 MB, 各 15 秒)。
- **再解析は古いモジュール出力を消さない。** 実測 17559_BSI: 再解析で `plasmidfinder_result.json` は 0 件に上書きされたのに `plasmidfinder_output/` には旧実行 (6/16) のファイルが残り、**JSON と出力が矛盾**した。しかも残った TSV の contig 名は**旧アセンブリのもの**で座標が現物と合わない。「出力があるか」だけで backfill 対象を選ぶと取りこぼす。
- **backfill でレポートを直すとき `backfill_sample_reports.py --force` を使わないこと。** あれはレポート全体を作り直すので、そちらが組み立てない `paidb` / `molecule_classification` / `assembly_circularity` / `vector_screen` / `bakta` / `plasann` が消える。**該当セクションだけ差し替える** (`backfill_plasmidfinder.patch_report` がその形)。
- パーサの `main()` は #24 のとおり `if "snakemake" in globals():` でガードすること (backfill から import するため)。
**該当ファイル**: `workflow/rules/stage1_plasmidfinder.smk`, `workflow/scripts/parse_plasmidfinder.py` (`build_result`), `workflow/scripts/backfill_plasmidfinder.py` (新規)

### 28.1 全モジュールの「無言の偽陰性」監査結果 (2026-08-05)
#28 を受けて全 26 ルール + 20 パーサを監査した。**判定基準は「外部ツールが落ちたとき、
パーサが 0 件 = 陰性として PASS を書いてしまうか」**の一点。

**露出していた 5 モジュール (いずれも修正済み)**:
| モジュール | 握り潰し方 | 修正 |
|---|---|---|
| **AMRFinderPlus** | `EXIT` を記録するだけで判定に使わず、**失敗時にヘッダのみの TSV を自分で書いていた**ためパーサが正常に読めてしまう | `HAVE_OUT` をヘッダ補完の**前**に評価し `AMRFINDER_ERROR` を書く |
| **ResFinder** | `\|\| true` | `PIPESTATUS` + 出力実在 → `RESFINDER_ERROR` |
| **PAIDB** | `\|\| true` (blastn) | 終了コード → `PAIDB_ERROR` |
| **VirulenceFinder** | DB ごとに `\|\| true` | DB ごとに判定 → `VIRULENCEFINDER_ERROR` |
| **ABRicate** | パーサが `except Exception: pass` で読み取り失敗を捨てていた | DB ごとに TSV の実在/サイズを見て `failed_databases` を出す |

**AMRFinderPlus が最重要**。全検体に走る NCBI 公式 AMR バリデーション層で、
かつ**「ヘッダのみ TSV を書いて下流を守る」という善意の作りが、そのまま
検査不能を陰性に見せる経路になっていた**。ツールは検出 0 件でもヘッダを書くので、
出力を見ても区別が付かない — **終了コードだけが唯一の根拠**。

**露出していなかったモジュール**とその理由 (パーサが出力実在で FAIL を出せる):
kaptive / cgMLST / SeqSero2 / MOB-suite / MEFinder / CheckM2 / fimtyper /
ShigaPass / SerotypeFinder / cefiderocolFinder / PlasAnn / PlasmidFinder。
`set +e` + `EXIT` 未使用のルールでも、パーサ側が守っていれば偽陰性にはならない。
**ルール単体を見て「危険」と判断しないこと — 判定はルールとパーサの対で行う。**

**実データでの影響 (NAS 全 257 検体)**: AMRFinder のヘッダのみ TSV が 4 件
(`yamaguchi` の Streptococcus)。ResFinder / ABRicate / VirulenceFinder / PAIDB は 0 件。
PlasmidFinder のような大規模な取りこぼしは**今回は無かった**が、
**4 件は「陰性」と「実行不能」が原理的に区別できない状態だった** (ログが既に消えており事後判定不能)。
検出スクリプトは `workflow/scripts/audit_silent_failures.py`。

**残った構造的な穴**: パーサ 20 個中 18 個が `main()` を無条件に呼んでいる (#24 のバグ型)。
今回触れた 4 個 (`parse_amrfinder` / `parse_resfinder` / `parse_abricate` +
既存の `parse_plasmidfinder` / `parse_bakta`) はガード済み。**backfill を書くときは
対象パーサのガードを先に入れること。**

### 28.2 「出力実在」ガードのファイル名を間違えると、守るはずのモジュールが全滅する
**症状 (実測 2026-08-14)**: kaoki_bsi 90 検体のうち **E. coli 14 検体すべて**
(= fimtyper が走る対象の全数) で `fimtyper_result.json` が `status=FAIL`。
警告文は `FimTyper を実行できませんでした (FimTyper failed (exit=0))` で、
**exit=0 なのに failed** という矛盾がそのまま出ていた。
**真因**: #28.1 で入れた「終了コード**と**出力ファイルの実在の両方で判定する」
ガードが `results_tab.tsv` を見ていたが、FimTyper が実際に書くのは
**`results_tab.txt`**。`-s` が常に偽になり、成功時にも `FIMTYPER_ERROR` が
書かれていた。**#28 の対策が、逆方向の偽陽性 (検査できているのに FAIL) を
作っていた**形。皮肉なことに `parse_fimtyper.py` の docstring には
「ファイル名は `results_tab.txt` (`.tsv` ではない)」と正しく書いてある。
**教訓**:
- **出力実在で判定するガードを書くときは、そのツールが実際に書くファイル名を
  実物で確認すること。** 名前を間違えると全数が落ちる。
- 「陰性」ではなく「FAIL」に倒れるので #28 の無言の偽陰性より発見はしやすいが、
  **対象菌種の全数が落ちる**ぶん影響は大きい。定期監査では
  「あるモジュールの FAIL 件数 == その対象菌種の検体数」というパターンを疑うこと。
- **`failed (exit=0)` のような自己矛盾した警告文は、判定条件そのものが
  壊れている合図。**
**復旧**: 出力 (`results_tab.txt` 等) は残っていたので **FimTyper は再実行不要**。
`workflow/scripts/backfill_fimtyper.py` (dry-run 既定) で 14 件すべて
FAIL → PASS に復旧した。書き換えるのはモジュール JSON と
レポートの `ecoli_typing.fimtyping` **だけ** (`backfill_sample_reports.py --force`
は使わない — #28)。**backfill 実装で踏んだ点が 2 つ**:
- `build_result()` は ERROR マーカーがあると無条件に FAIL を返す。マーカー自体が
  誤りなので、**マーカーを除いた一時複製**に対して読み直す (dry-run で現物を触らない)。
- contigs.fasta との新旧比較は **±600 秒の余裕**を持たせる
  (`audit_stale_outputs.py` の `MARGIN_SEC` と同値)。NAS への `cp -a` は
  コピー順で mtime が数秒前後するため、余裕なしだと健全な検体まで弾かれる。
**妥当性の確認**: 45 ペアは同一分離株を独立に 2 回シークエンスしたものなので、
**ペア 7 組すべてで FimH 型が一致した**ことが結果の裏づけになった。
**該当ファイル**: `workflow/rules/stage1_fimtyper.smk`,
`workflow/scripts/parse_fimtyper.py`, `workflow/scripts/backfill_fimtyper.py` (新規)

### 28.3 モジュール単体の再実行はアセンブリを作り直さずにできる
同じ監査で `plasmid_outbreak` が 3 検体 (16656 / 20816_BSI / 22178_BSI) で
旧アセンブリ由来のまま残っていた (`audit_stale_outputs.py` で検出)。
本番走行中に `register_plasmids_to_db` が例外で落ちて `registration.json` が
作られず、下流の `check_plasmid_outbreak` も走らなかったのが原因
(rule ログが 37 本ではなく 36 本になっているのが痕跡)。
**単独で再実行したら 3 件とも成功**したので、並走時の NAS 競合による
一過性の失敗と考えられる。再実行は bakta の on-demand と同じ手法で、
**アセンブリを作り直さずに当該ルールだけ**回せる:

```bash
snakemake --snakefile $W/workflow/Snakefile --configfile $W/config/config.yaml \
  --allowed-rules register_plasmids_to_db check_plasmid_outbreak \
  --config input_dir=$NAS_RESULTS results_dir=$NAS_RESULTS samples=16656 \
  plasmid_db_path_override=<グループの plasmid DB> \
  --cores 1 --rerun-triggers mtime --rerun-incomplete \
  $NAS_RESULTS/16656/plasmid_outbreak/query.json
```

**`--allowed-rules` は引数を貪欲に取るので直後に `--config` を置く**こと。
これを省くと後続のターゲット指定まで食われる。`classify_input` を走らせないのも
重要で、走らせると NAS results を「サンプル入力」として走査し
`input_class.json` を mode=unknown に上書き破壊する (既知)。

### 29. cgSNP のスキーム解決は「属内に複数スキームがある属」で丸ごと落ちる
**症状 (実測 2026-08-05)**: `Klebsiella variicola` / `quasipneumoniae` / `grimontii` /
`michiganensis` / `aerogenes` の **19 検体**が
`no cgSNP scheme for species '...'` で cgSNP を一切取れていなかった。
菌種同定も MLST も正常 (`mlst` は `klebsiella` / `koxytoca` / `kaerogenes` スキームで
ST1423・ST216 等を正しく返していた) のに、cgSNP だけが落ちる。

**原因**: `resolve_target_scheme()` は `stringmlst_species_map` のキー (`属_種` 形式) を
**属名でマッチし、候補が複数あるときだけ種小名一致を要求する**。
Enterobacter は属内にスキームが 1 つ (`Enterobacter_cloacae`) しかないので
E. hormaechei も自動的に拾えていた。ところが **Klebsiella は属内に 3 つ**
(`Klebsiella_pneumoniae` / `_oxytoca` / `_aerogenes`) あるため種小名一致が必須になり、
**スキーム名になっていない近縁種が全部 (None, None) に落ちる**。
Enterobacter で動いていたので誰も気づかなかった。

**解決**: `config.core_snp.species_scheme_map` に
`菌種名 → {stringmlst_db, species_dir}` を明示する層を追加し、genus 推定より優先させる。
`subsp.` 付きの菌種名も前方一致で拾う。

**重要な設計判断 — ST 体系は共有するが参照ゲノムは種ごとに分ける**:
- K. pneumoniae complex (pneumoniae / variicola / quasipneumoniae / quasivariicola /
  africana) は PubMLST の **klebsiella スキームを共有**するので `stringmlst_db` は共通。
- しかし **`species_dir` は種ごとに分ける** (`Kvariicola` / `Kquasipneumoniae` …)。
  K. pneumoniae と K. variicola の **ANI は約 95%** で、参照を共有するとマッピング率が
  落ちてコアゲノムが痩せる (#26 の `min_core_fraction` に引っかかる)。
  加えて **ST 番号が同じでも別種なら別クラスタ**なので BAM DB も分離が要る。
  実際 ST1423 は K. variicola の系統で、K. pneumoniae 3,154 株の型別け表に 1 件も無い。
- したがって `Kvariicola/representative_genomes/ST1423/` のように**種別のディレクトリを
  新設**する。旧実行が `no reference genome for Kpneumoniae ST1423` を出していても、
  **そこを埋めてはいけない** (別種の参照を当ててしまう)。

**Klebsiella だけの話ではない — 一般則**: 属内にスキームが**1 つしか無い**属では
genus マッチが常に成立するので、**その属のあらゆる種がそのスキームの species_dir に
吸い寄せられる**。Klebsiella (スキーム 3 つ) では「解決できずに落ちる」形で露見したが、
**スキームが 1 つの属では落ちずに「遠い参照へ静かに当たる」形になる**ので質が悪い。
実測 2026-08-05: `Citrobacter farmeri` の 17580 / 17580_BSI が `Cfreundii` の参照に
割り当てられていた (**ANI 約 88〜91%**)。ST 体系の共有自体は正しく mlst も cfreundii
ST1200 を返すが、参照ゲノムとしては遠すぎてコアゲノムが痩せ、
**距離が実際より近く出る方向に壊れる** (#26 と同じ壊れ方)。
`Cfarmeri` / `Camalonaticus` / `Ckoseri` を種別ディレクトリに分けた。
**参照が未整備なら "no reference genome" で止まるが、遠い参照に当てて痩せたコアゲノムを
黙って出すより止まる方が良い。**
点検は `workflow/scripts/audit_species_dir_mismatch.py`
(「species_id の菌種」と「species_dir が想定する菌種」を突き合わせ、
既知の複合種 — Enterobacter cloacae complex, Campylobacter jejuni/coli — は除外する)。
**新しい菌種が同定されたら走らせること。**

**再解析で自然に直るもの**: 実測で `Enterobacter hormaechei` の 17948_BSI が
`Salmonella` の参照を要求していた ([[project_cgsnp_stringmlst_species_misassign]] の
交差反応バグの残骸)。修正済みなので**再解析すれば species_id 経由で Ecloacae に
解決される**。古い `mapping_info.json` の内容を「現在の挙動」と読み違えないこと。

**該当ファイル**: `workflow/scripts/run_core_snp_map.py` (`resolve_species_override`,
`resolve_target_scheme`), `workflow/rules/stage2_core_snp.smk`,
`config/config.yaml` の `core_snp.species_scheme_map`,
`tools/backfill_missing_references.py` の `SPECIES_CONFIG`,
`workflow/scripts/audit_species_dir_mismatch.py`

### 29.1 参照ゲノム補充ツールの落とし穴
`tools/backfill_missing_references.py` を実際に回して踏んだもの。

- **`mlst --scheme` に渡す名前が実在しないと、黙って「該当 ST 無し」になる。**
  `SPECIES_CONFIG` の 7 件が実在しない名前だった:
  `kpneumoniae`→**`klebsiella`**, `senterica`→**`senterica_achtman_2`**,
  `smarcescens`→**`serratia`**, `pmirabilis`→**`proteus`**,
  `lmonocytogenes`→**`listeria_2`**, `abaumannii`→`abaumannii_2`,
  `ecoli`→`ecoli_achtman_4`。数百ゲノム落として型別けし、
  何も見つからずに終わるので**失敗が成功と同じ見た目になる**。
  起動時に `mlst --list` と突き合わせて落とすようにした。
- **PATH に他 conda env の bin を足さないこと。** bwa を使いたくて
  `PATH=/opt/mambaforge/envs/core_snp_env/bin:$PATH` としたら、
  core_snp_env の **Perl 5.22 が py39 の 5.32 を隠して** `mlst` が
  `Perl v5.32.0 required` で即死した。`--bwa-bin` で実体を直接指す。
- **`datasets` CLI は 3 ワーカーのどこにも入っていない。** py39 は壊すと影響が
  大きい共有環境なので (memory: py39 環境全損の件)、**NCBI Datasets の REST API を
  `urllib` で直接叩く経路**を実装した。追加インストール不要。
  メタデータは `/genome/taxon/{taxon}/dataset_report`、本体は
  `/genome/accession/{acc}/download` (ZIP)。
- **既存の `{ref_dir}/{species}/mlst_results.tsv` を先に引くこと。** 初回構築時の
  型別け結果が残っており (Kpneumoniae は 3,154 件)、目的の ST があれば
  **1 ゲノム落とすだけで済む**。ただし**表の ST を鵜呑みにせず mlst で再確認する**
  (スキーム更新で番号が変わりうる)。
- **「N ゲノム走査しても見つからない」ときは、まず `taxon` / `extra_taxa` の
  指定漏れを疑うこと。** 実測 2026-08-05: `Ecloacae ST252` が
  **733 ゲノムを全走査しても見つからなかった**が、真因は探索対象が
  `cloacae` + `hormaechei` + `kobei` の 3 種だけだったこと。
  検体 17556 は **E. asburiae**、17561 は **E. ludwigii** で、
  **そもそも当該菌種のゲノムを 1 件も見ていなかった**。
  対象外の ECC メンバーに complete ゲノムが 275 件あり、
  asburiae を足したら ST252 が即座に見つかった
  (置かれた参照は `Enterobacter asburiae strain 5549 chromosome, complete genome`)。
  **走査数の多さは網羅性の証拠にならない。**
- **ST=any (STany) で種レベル参照を置ける。** `find_reference()` は ST 固有参照が
  無いとき **STany に自動フォールバックする**ので、目的の ST の公開ゲノムが
  存在しない菌種はここを埋めれば cgSNP が動く (**2 株以上で距離行列は出る**。
  系統樹は `min_strains` 以上必要)。`--target {species}:any` で配置でき、
  品質順ソートの先頭が選ばれる (実測 Cfarmeri は 1 contig 4.92 Mb が採用された)。
  **同種であることだけが担保で ST は揃わない**ため、複数 ST が同じ木に混ざる点は
  解釈時に留意すること。
- **配置時に `bwa index` を張っておくこと。** `run_core_snp_map.py` は索引が
  無ければ実行時に張るが、同じ ST を複数サンプルが同時に使うと並行生成になる。

### 30. 小型プラスミドは 2026-07-27 以前のアセンブリでは系統的に失われている
**発端**: 16656 で「短い環状 contig が大量に (8 本) 出ている」ことをアセンブリ異常と疑った。
**結論: 異常ではなく実在の小型 Col プラスミドで、むしろ旧版が取りこぼしていた方が問題。**

**16656 の検証 (根拠を 4 つ揃えた)**:
1. **同一分離株の別ライブラリ (16656_BSI, 6/16 解析) のアセンブリには 1 本も無い**
   (13 contig 中 7 本が 0% 一致) が、**その BSI 側の生リードには大量に在る**。
   30-mer シードで数えると、染色体が 23 hits/seed に対し小型 contig は
   1,700〜3,000 hits/seed = **染色体の 70〜130 倍**。つまり
   「無かった」のではなく「**アセンブルされなかった**」。
2. PlasmidFinder が **curated な Col レプリコンを検出** (`Col(IMGS31)` 100% 一致、
   `Col(pHAD28)`)。MOB-suite の mash 最近傍距離は **0.0008** (既知の K. pneumoniae
   プラスミドとほぼ同一)。
3. 小型 contig 同士・染色体との重複は 0〜8% = **反復配列の重複計上ではない**。
4. **バーコード漏れ (crosstalk) でもない**。同アカウント 303 contig と突き合わせると、
   8 本中 7 本はどの検体にも出ず、`contig_7` だけが 2 検体 (17558 / 17559_BSI) と共有
   = 施設内のプラスミド疫学として自然な分布。crosstalk なら高コピー分子が
   同一ランの多検体に一斉に出るはずで、そうなっていない。

**全 45 ペアでの定量 (小型 contig <20 kb の本数)**:
新規側 (7/31〜8/5 解析) **51 本** vs BSI 側 (6/16〜6/19 解析) **21 本**。
**18 ペアで新規側が多く**、BSI 側が多いのは 3 ペアだけ (うち 17559_BSI は
8/5 に再解析済み = 修正後)。両側とも 8/4 解析の 10 ペアは**全ペアで差 0**。
→ 差は菌株の違いではなく**解析日 (パイプライン版) で説明できる**。

**運用上の帰結**:
- **修正前後のアセンブリ間でプラスミド/レプリコンを比較しないこと。**
  「レプリコン一致」も「プラスミド差分あり」も同じくらい信用できない。
  [[project_bsi_pair_comparison]] の「旧版はモジュール欠損」と同型の罠で、
  こちらは**モジュールではなくアセンブリそのもの**が違う。
- 小型プラスミド回収の修正は `-l/-m 2000` + `target_depth` + `--asm-coverage` 無効化
  (2026-07-27) と層化ダウンサンプリング (#21)。**効いている**ことが実証された。
- **concatemer_collapse が小型環状 contig で発火するのは正常。** ONT のリードが
  小さい環を何周も読むと直列多量体になる。16656 では 4 本が縮約された
  (`contig_8`: 16,593 bp → 4,148 bp × 4 コピー等)。
- 16656 の `downsample_info.json` は `species: "..."` / `genome_size: 8,281,440`
  (mash 由来) で、**#24 の 2 バグが生きていた時期 (7/31 解析) の検体**。
  ダウンサンプリングは発火していない。

### 31. 公共 DB に無い ST は、自施設の閉環ゲノムを参照に繰り上げてよい
**背景**: `backfill_missing_references.py` は NCBI RefSeq を探すが、**その ST の
complete genome が公共に 1 件も無い**ことがある (実測 2026-08-12: *Citrobacter
freundii* ST581 / *Enterobacter ludwigii* ST15)。この場合 cgSNP は
`no reference genome for {species_dir} ST{st}` で skipped になり打つ手が無い。
一方、当該検体自身が **1 contig の閉環染色体**として組み上がっていることがある。
outbreak 解析で標準的な「in-study closed genome を参照にする」運用にあたるので、
**品質ゲートを通れば繰り上げてよい**。ツールは
`tools/promote_inhouse_reference.py` (dry-run 既定)。
- **染色体だけ置くこと。** `run_core_snp_map.filter_chromosome_only()` は
  FASTA ヘッダに文字列 `plasmid` があるかで除外判定するので、Flye のヘッダ
  (`contig_2_length:76661_cov:111_circular`) のままだとプラスミドが参照に残る。
  抽出は `molecule/molecule_classification.json` (#19 の単一の真実源) から行う。
  **書き出すヘッダに `plasmid` の語を入れないこと** (自分で除外されてしまう)。
- **実体コピーで凍結する。シンボリックリンクは不可。** `input/contigs.fasta` は
  それ自体がリンクで dangling しうる (#17)。さらに元検体を再解析すると中身が
  変わり、**その参照で作った BAM DB がまるごと無効になる**。
- **命名を公共アクセッションと区別する** (`TAROT_{sample}_{species_dir}_ST{st}.fna`)。
  `find_reference()` は `*.fna` を glob して `[0]` を採るので **ST ディレクトリには
  1 本だけ**。素性は `REFERENCE_INFO.json` に `provenance: in-house` で残す。
- 品質ゲート (既定): 閉環 1 contig / CheckM2 完全性 ≥95% ・汚染 ≤5% /
  genome_size_ratio 0.9〜1.15 / 曖昧塩基 0 / mlst の ST が一致。
- **自家参照バイアスは距離を歪めない。** 参照由来検体の距離は構造的に 0 に寄るが、
  リードは全検体独立にマップされるのでペアワイズ距離は保たれる。参照側の
  ONT 系統誤差も全検体に共通に効くので相殺する (効くのは局所ミスアラインで
  コアが痩せる方向のみ)。
- **品質の実測的な裏付けの取り方**: 同一分離株を独立に 2 回シーケンスした検体が
  あれば dnadiff で比較する。実測 17564 vs 17564_BSI は **SNP 1 / Indel 7 /
  アライン 100%** で、公共 complete genome に見劣りしないことが示せた。
- **`min_strains` (既定 4) 未満では系統樹は出ず距離行列だけ**になる。ペアの
  同一株判定にはそれで足りる。
**踏んだバグ**: `_ensure_bwa_index` の一時領域が `/tmp` (ワーカーの ext4) で、
参照は NAS (CIFS) なので `os.replace` が **`Invalid cross-device link`** で必ず落ち、
**`.fai` が無いまま参照が配置される**。これは #29.1 の faidx 同時生成事故
(1,486,413 件のエラー) を防ぐための関数自身が機能していなかったということ。
`tempfile.mkdtemp(dir=reference.parent)` で同一 FS に作れば直る。
`backfill_missing_references.py` も同じ形だったので併せて修正済み。
**ECC の扱い**: Enterobacter は属内スキームが 1 つなので ECC 全種が `Ecloacae` に
吸い寄せられる (#29 の一般則)。ただし **ECC は ST 番号が実質的に種を分けている**
(実測: ST252=asburiae / ST78・113・1331=hormaechei / ST15=ludwigii) ため、
ST ごとに種の合った参照が置かれている限り実害は出ていない。
**参照を新規に置く種から順に分離する**方針とし、2026-08-12 に
`Enterobacter ludwigii → Eludwigii` のみ追加した。hormaechei / asburiae は
`Ecloacae` のまま — 移すと bam_db のパスが変わり、既存の完了済み検体
(ST78 が 8 検体) と同じ木に乗らなくなる。
**該当ファイル**: `tools/promote_inhouse_reference.py` (新規),
`tools/backfill_missing_references.py` (`_ensure_bwa_index`),
`config/config.yaml` の `core_snp.species_scheme_map`

### 32. mlst の「同一アリル多重ヒット」は ST 決定を諦める理由にならない
**症状 (実測 2026-08-13, TAS005 / E. coli)**: `icd(12,12)` のため ST が `-` になっていた。
**原因**: mlst (Seemann) はプロファイル表を**文字列キーで引く**ので `12,12` が
見つからず ST を `-` にする。だが `12,12` は「アリルが 2 種類あって決められない」
ではなく「**同じアリル 12 が 2 箇所で完全一致した**」という意味で、
プロファイル自体は一意。実際 12-12-8-12-15-2-2 は PubMLST `ecoli_achtman_4` の
**ST11 (ST11 Cplx = O157:H7 系統)** に一意に一致する
(icd 以外 6 座位が同じ ST は他に 23 個あるが全て icd が別番号)。
`parse_mlst.py` は `st == "-"` をそのまま WARN で通していただけだった。
**同一番号の重複が起きる主因はアセンブリ側** — Flye が解けなかった反復は
それを挟む contig の両端に重複出力される (#20)。
**混合株・真のパラログなら通常アリル番号が食い違う (`12,20`)** ので、
同一番号 2 つは重複由来を強く示唆する。
**解決**: `parse_mlst.build_result()` (純粋関数, 単一の真実源) が
**全ヒットが同一番号の座位だけ**を潰し、mlst 同梱のプロファイル表
(`<mlst>/db/pubmlst/{scheme}/{scheme}.txt`, `config.mlst.db_dir` で上書き可)
を引き直して ST を確定する。ネットワーク不要。
- **番号が食い違う座位が 1 つでもあれば潰さない** (`ambiguous_loci` に記録し
  「混合株を疑え」と出す)。`~n` / `n?` / `-` を含むプロファイルも手を出さない
  (そもそも表引きできない)。
- **痕跡を消さない**: `allelic_profile` は生表記 (`12,12`) のまま、潰した後を
  `resolved_allelic_profile`、重複座位を `duplicated_loci`、
  `st_resolution: "deduplicated"` を残す。UI と HTML エクスポートは
  該当アリルを黄色くし「重複除去で確定した ST」である旨を必ず併記する
  (**ST の数字だけ見せると mlst が返した ST と区別が付かない**)。
- 副次効果: `run_core_snp_map.py` の「stringMLST 不発 → mlst の ST に
  フォールバック」経路が救われる (ST が `-` だと cgSNP が skipped になり得た)。
- 既存検体は `workflow/scripts/backfill_mlst.py` (dry-run 既定)。
  **mlst は再実行せず** `mlst/mlst.tsv` を読み直すだけ。レポートは
  `mlst` セクションだけ差し替える (#28: `backfill_sample_reports.py --force` は
  paidb / molecule_classification 等を消すので使わない)。
  プロファイル表が引けないと救済が 1 件も起きないので、起動時に probe して
  WARN を出す (#29.1 の「失敗が成功と同じ見た目になる」対策)。
**該当ファイル**: `workflow/scripts/parse_mlst.py` (`build_result`,
`find_profile_table`, `lookup_st`), `workflow/scripts/backfill_mlst.py` (新規),
`workflow/rules/stage1_mlst.smk` (parse_mlst に `params.db_dir`),
`workflow/scripts/per_sample_report.py` (`_build_mlst_section`),
`frontend/src/pages/SampleDetail.tsx`, `frontend/src/lib/htmlExport.ts`,
`config/config.yaml` の `mlst.db_dir`

### 33. 大腸菌 病原型アラート (DEC / ExPEC) — stx サブタイプの出所と座位の二重計上
**目的**: 下痢原性大腸菌 (DEC) 6 病原型と ExPEC の重要病原遺伝子を検出したとき、
1 枚のカードに警告としてまとめる。**新規ツールは実行しない** — VirulenceFinder /
SerotypeFinder / ShigaPass の既存出力を再解釈する層。

**判定は `workflow/scripts/classify_dec_pathotype.py` のみが行い**、レポートの
`dec_alerts` セクションに焼き込む。frontend (`DecAlertsCard.tsx`) も
`htmlExport.ts` もそれを読むだけで判定式を持たない (#19 の二重化事故の再発防止)。
遺伝子カタログと名称正規化は `workflow/scripts/dec_markers.py` に分離。

**実 DB を確認して分かったこと (2026-08-13)**:
- **stx のサブタイプは `stx` DB からは取れない。** `stx.fsa` (160 エントリ) の
  遺伝子名は **`stx1` / `stx2` の 2 種のみ**。サブタイプ (stx1a/1c/1d/1e,
  stx2a〜stx2o) は **`virulence_ecoli.fsa` にのみ** `stx2c-O157-C394-03` 形式で
  137 エントリある。**HUS リスクの層別化は virulence_ecoli 依存**。
- **同一座位が 2 回出る。** E. coli では両 DB が走るので、実測 TAS003 で
  `stx1` (db=stx) と `stx1a-O157-FLY16` (db=virulence_ecoli) が**同じ contig の
  同じ座標**にヒットした。パーサの dedup キーは (gene, contig, position) なので
  名前が違う両者は残る (パーサとしては正しい)。**分類器が (contig, position) で
  束ね、subtype 付きを採用する**こと。generic 名は virulence_ecoli が拾えない
  発散型の安全網として併用する。
- **ABRicate VFDB は DEC のクロスチェックに使えない。** 実データ 118 検体の
  VFDB ヒット 785 遺伝子に stx / eae / ipaH / elt / est / agg* / bfp / ehxA は
  **1 件も無く** (共通は `senB` のみ)、命名体系も別でサブタイプも持たない。
  DEC 判定は virulence_ecoli を単一の権威とする。
- **遺伝子名は装飾付き**なので完全一致では引けない: `eae-g01-gamma_1`→`eae`(γ1)、
  `eltIAB-*`→LT-I / `eltIIAB-*`→**LT-II** (動物由来。単独では ETEC と断定しない)、
  `estah-*`→STh / `estap-*`→STp、`papA_F43`→`papA`、`kpsMII_K1`→`kpsMII`(K1)。
- DEC の定義的マーカーは全病原型で収載済み。非収載は補強因子のみ
  (`escV`/`ler`/`set1A`/`daaC`/`ipaB`/`ipaC`/`icsA` 等)。

**`parse_virulencefinder.py` の coverage が全検体で空だった (同時修正)**:
実ヘッダは `Query / Template length` (スラッシュ前後に空白) だが、パーサは
空白なしのキーだけを引いていた。空白を潰した正規化キーで引くよう修正し、
`coverage_fraction` (0-100%) も持たせた。**旧データは `None` = 「不明」であって
「0」ではない**ので、閾値で弾かないこと。`main()` のガード (#24) も併せて追加。

**検査不能を陰性として描画しない (#28)**: `status` を
`ok` / `skipped` (対象外菌種) / `unavailable` (**検査不能**) の 3 値で持ち、
UI は unavailable を赤枠で明示する。実測 TAS003 は stx1a+stx2c+eae γ1 の典型的
O157 EHEC でありながら **SerotypeFinder が FAIL** しており、最も O157 の確認が
必要な検体で血清型が取れていなかった。閾値未満で落としたヒットも
`borderline_markers` に残す (**stx が閾値ギリギリで消えるのが最悪の偽陰性**)。

**実データで見つかった要注意パターン**: TAS008 は **O157:H7 / eae+ / stx−**。
stx ファージは脱落しうるので、これを単なる atypical EPEC として流すと
「O157 だが stx 陰性」という疫学上重要な所見が埋もれる。
`stx_negative_high_risk_serotype` として WARNING を別立てしてある。

**ExPEC は Johnson の定義** (P線毛 / S・F1C線毛 / Dr接着素 / アエロバクチン /
群2莢膜 の **5 群中 2 群以上**) を採用。重症度は **INFO 止まり** —
ExPEC マーカーは健常者の常在株にも広く分布し、CRITICAL にすると DEC が埋もれる。
サブグループ警告として NMEC (`kpsMII_K1`+`neuC`+`ibeA`)・UPEC・pks 島 (`clbB`)・
HPI (`fyuA`+`irp2`) を出す。

**既存検体**: `workflow/scripts/backfill_dec_alerts.py` (dry-run 既定)。
ツールは再実行せず、`dec_alerts` セクションだけ差し替える
(`backfill_sample_reports.py --force` は paidb / molecule_classification 等を
消すので使わない)。coverage は残っている `results_tab.tsv` から補完するが、
**TSV の (gene, contig, position) 集合が JSON と一致するときだけ**にする
(#28 の実測どおり出力ディレクトリには旧実行の残骸が残ることがあり、
座標が現物と合わない TSV から持ち込む方が有害)。
**該当ファイル**: `workflow/scripts/dec_markers.py` (新規),
`workflow/scripts/classify_dec_pathotype.py` (新規),
`workflow/scripts/backfill_dec_alerts.py` (新規),
`workflow/tests/test_dec_alerts.py` (新規),
`workflow/scripts/parse_virulencefinder.py` (coverage + ガード),
`workflow/scripts/per_sample_report.py` (`_build_dec_alerts_section`),
`frontend/src/components/DecAlertsCard.tsx` (新規),
`frontend/src/lib/api.ts` (`DecAlerts` 型), `frontend/src/lib/htmlExport.ts`
(`renderDecAlerts`), `frontend/src/pages/SampleDetail.tsx`,
`config/config.yaml` の `dec_alerts` セクション

### 34. dorado の GPU は 1 ジョブで飽和する — 重ねても速くならず、到達後の basecall は丸損
**背景**: New Job から Dorado Basecalling を 2 本投入したら GPU に余裕があるか、
という問いから 2 件の無駄が見つかった。どちらも「GPU が空いているように見えて
実は空いていない / 空けても意味が無い」という同じ誤解に根がある。

**(a) ジョブを重ねてもスループットは増えない。**
dorado は `--device` を渡していないので **1 プロセスが全 GPU を掴む**。さらに
1 ジョブが `_run_distributed` で**全ワーカーにまたがる** (各ワーカーが作業キューから
pod5 を 1 つずつ取る) ので、**1 ジョブ走らせた時点で 3 台とも埋まっている**。
実測 2026-08-14 (kaoki_stec, 3 ワーカー): 単独 26 秒/chunk → 2 本目が合流した
時点で **61 秒/chunk (単独時の 43%)** に低下し、**合計は横ばい〜微減**。
`_preflight_workers` は SSH 疎通とディスク残量しか見ておらず GPU 使用率も VRAM も
チェックしないため、3 本目も普通に受け付けて全員が遅くなる。
**計測方法**: NAS の `accounts/{group}/dorado_runs/{job_id}/demux/chunk_NNN/` の
birth time と mtime の差 (`stat -f '%SB' / '%Sm'`)。**同時に走っている chunk 数 =
ワーカー台数**なので並列度もここで分かる。API を叩く必要は無い。

**解決**: `_gpu_slot` (asyncio.Semaphore) で basecalling 区間を
`dorado.max_concurrent_basecalling` 本 (既定 2、0 以下で無制限) に制限する。
- **囲むのは basecalling だけにすること。** `monitoring` (coverage 判定) と
  `downstream` (Snakemake 完了待ち) は GPU を使わないので、そこまで含めると
  **下流解析の完了待ちでベースコールが詰まる**。
- **realtime はラウンド単位で確保する。** `rescan_max_seconds` 既定 12 時間の間
  pod5 の到着待ちでアイドルするので、ジョブ全体で握ると空いた GPU を遊ばせたまま
  後続を待たせる。
- **`queued` が長時間続くようになるので `delete_job` でタスクを畳むこと。**
  止めずに `_jobs` から消すと、順番が回ってきたときに **UI に出ないジョブが
  basecalling を始める**。`queued` の表示側 (型 / "Queued" ラベル / ポーリング継続)
  は既にあったが、`DoradoJobDetail` の `phase_detail` カードは
  `status === 'basecalling'` でしか描画しないので待機理由用のカードを足した。

**(b) Coverage Progress が 100% になった後も basecalling が走り続けていた。**
`threshold_met` になった時点で `_measure_barcode_coverage` が下流解析を起動して
おり、**以降に basecall したリードはその解析には二度と混ざらない** (起動時点の
fastq を読んで走っているため。`_run_realtime` の docstring にも「閾値到達済みの
バーコードには追加しない」と明記されている)。原因は
`_incremental_monitor_loop` が全到達を検知して**自分のループを抜けるだけ**で、
`_worker_loop` は作業キューの pod5 を最後まで処理し続けていたこと。
**解決**: `_should_stop_basecalling(job)` を `_worker_loop` が**次の pod5 を
取りに行く前**に見て抜ける。`_basecall_pod5_batch` の単一ワーカー逐次ループと
`_recover_workers` の復帰ループも同じフラグを見る。
- **実行中のチャンクは中断しない。** リモートは nohup で走っており、途中で殺すと
  中途半端な BAM が NAS に残る。チャンク境界で止めるので打ち切り時に最大で
  ワーカー台数ぶん余分に処理される。
- **`job.barcodes` が空のときの `all([]) == True` を明示ガードすること。**
- **打ち切りを WARNING で出さないこと。** `_run_distributed` 末尾の「未処理 pod5」
  ログをそのまま使うと、本物の取りこぼし (ワーカー全滅等) と区別が付かなくなる。
- **効かない経路**: batch + ワーカー 1 台 (`_run_basecalling_single`) は pod5
  ディレクトリ全体を 1 本の nohup スクリプトで流すので途中打ち切りができない。
  この経路はそもそも並行 coverage 判定が無い (basecalling 完了後に
  `_monitor_coverage_loop` が回る) ので対象外。

**(c) `api/` の編集は実行中の dorado ジョブを消す — さらにリロード自体が刺さる。**
API は `uvicorn --reload --reload-dir .../api` で動いており、`_jobs` は
**インメモリ**、オーケストレーションは asyncio タスクなのでプロセスと心中する。
リモートで nohup 済みの現チャンクだけは走り切るが次の pod5 は誰も投げない。
再投入しても job_id が変わり `run_dir` が別になるので**完了済みチャンクの `.done`
も再利用されない**。**編集は必ずジョブが無い時に行うこと。**
加えて、**フロント (Vite プロキシ経由) の SSE ログストリームが開いていると
リロードが完了しない**。旧ワーカーは graceful shutdown に入るが SSE 接続が
自然に閉じないため待ち続け、旧ワーカーが終わらないので新ワーカーも上がらず
**API 全体が無応答になる** (curl は HTTP=000)。見分け方は
`lsof -nP -iTCP:8000 -sTCP:LISTEN` に**親 PID しか出ない** (旧ワーカーが LISTEN を
手放している) + `-sTCP:ESTABLISHED` に `node`(Vite) ↔ Python が残っていること。
**SIGTERM では死なない** (既に SIGTERM 処理中)。`kill -KILL <旧ワーカー PID>` で
リローダが即座に新ワーカーを spawn して復旧する (同じインタプリタで再起動されるので
arm64/x86_64 の問題は起きない)。
**該当ファイル**: `api/services/dorado_runner.py` (`_gpu_slot`,
`_max_concurrent_basecalling`, `_should_stop_basecalling`, `_run_job`,
`_worker_loop`, `_recover_workers`, `_run_realtime`, `delete_job`),
`frontend/src/pages/DoradoJobDetail.tsx` (待機中カード),
`config/config.yaml` の `dorado.max_concurrent_basecalling`

### 35. cgSNP の比較集団を ST より細かく切る (E. coli = fimH サブタイプ)
**動機**: cgSNP DB の「Species × ST groups」は表示上の分類ではなく、
**`bam_db/{species}/{群}/` がそのまま系統樹の比較集団**
(`collect_bams` はこのディレクトリ 1 つしか見ない)。E. coli では ST だけでは粗く、
ST 内の亜系統を分けたい。2026-08-14 に fimH 型 (FimTyper) をサブタイプ層として導入。

**設計の要点 (壊さないこと)**:
- **群 (`group`) と ST を別物として持ち回る。** 群は `"{ST}_{subtype}"`
  (例 `11_H82`)、ST は素の `11`。**参照ゲノムは ST 単位にしか存在しない**
  (`representative_genomes/ST{st}/`) ので、参照解決に群を渡すと必ず外す
  (検証済み: `find_reference(st="11_H82")` → None)。`mapping_info.json` /
  `metadata.json` / `core_snp_result.json` は ST と subtype を**別フィールドで**持つ。
- **判定は `workflow/scripts/core_snp_subtype.py` だけが行う** (#19 の二重化事故の
  再発防止)。Snakemake ルールも移行ツールも `resolve_subtype()` を呼ぶだけ。
  API 側にあるのは表示用の**分解**のみで、判定ロジックは持たせていない。
- **サブタイプのラベルに `_` を含めない。** 群名の分解は最初の `_` で行う
  (ST は数値か `any` で `_` を含まないので曖昧にならない)。`normalize_label()` が
  `[A-Za-z0-9.-]` 以外・24 文字超・パス区切りを弾き、通らなければサブタイプ無し。
  **推測でディレクトリを作らない。**
- **型が確定しない検体は ST のみの群に残す** (ユーザー決定)。FimTyper が
  FAIL (= 検査不能) でも WARN (= 新規変異体) でも `{ST}_HNA` のような群を作らない。
  検査不能を独立クラスタに化けさせないため (#28 と同じ趣旨)。理由は
  `subtype_status` (`ok`/`not_configured`/`missing`/`unavailable`/`no_call`/`invalid`)
  と `subtype_detail` に必ず残し、UI は `unavailable` を
  **「fimH 陰性ではなく判定できていない」**と明示する。
- **`core_snp_map` の input に fimtyper の結果を足す**
  (`_core_snp_subtype_inputs`)。まだ書かれていない結果を「型なし」と読むと
  ST 群に登録され、**登録先は後から変えられない** (他検体の系統樹が既にその群を
  参照する)。追加コストはゼロに近い — 既に mlst を待っており、同じ段で走る。
  config が空なら 0 件 = 従来と同一の依存関係。
- **BAM キャッシュも群単位で切る** (`localize_bams`)。ST だけで切ると別サブタイプの
  BAM が同じキャッシュに混ざる。

**既存 DB の移行 = `tools/migrate_bam_db_subtype.py` (dry-run 既定)**:
- BAM/BAI を新しい群へ移し、移動元・移動先の `metadata.json` を
  **一時ファイル + `os.replace`** で書き換える (#25)。
- **各検体の `core_snp/mapping_info.json` にも `group` を書く。** 系統樹だけ
  作り直す経路 (`--allowed-rules core_snp_phylo`) は core_snp_map を回さないので、
  **mapping_info.json が唯一の群の手がかり**。ここを忘れると次の phylo が
  古い群を見に行く。
- 既に `{ST}_{subtype}` になっている群はスキップ = **冪等**。
- **metadata に書く BAM パスを、ツールを実行したマウントから組み立て直さないこと。**
  2026-08-14 に実際にやらかした: 移行ツールを Mac
  (`/Volumes/QNAP_Share/tarot/...`) から走らせたところ `metadata.json` に
  そのパスが書かれ、NAS を `/mnt/nas/tarot/...` で見るワーカー側では
  `collect_bams` の `if not bam_path.exists(): continue` に全部引っかかって
  **移行した 44 株が黙って比較集団から消えた** (エラーにならず insufficient)。
  対策は `repoint_bam_path()` — **記録済みパスの末尾
  `/{species}/{src_group}/{sample}.bam` だけを差し替える**。どのマウント越しに
  実行しても元の表記が保たれ、形が想定と違えば None を返して移動を取り消す
  (推測でパスを書かない)。同じ罠は reference のパスや今後の同種ツール全部にある
  — **NAS 上の JSON にパスを書く処理は、実行環境のマウントに依存させないこと。**
- 事故後の修復は `--repair-paths --canonical-db-path <ワーカーから見えるパス>`
  (ファイルは動かさずパス文字列だけ直す。冪等)。**正規パスの自動判定はしない** —
  正規パスは配置の性質であってデータの性質ではなく、実測で kaoki_stec は
  全群が移行済みだったため 22 件すべてが Mac のパスで「全一致」し、
  自動判定だと壊れたまま素通りした。
- dry-run は移行後の群ごとの株数を出し、2 株未満 (解析不可) / 4 株未満
  (距離行列のみ) に印を付ける。**BAM の中身も既存の系統樹結果も触らない。**

**実データでの影響 (2026-08-14, NAS 全アカウント)**: E. coli 44 株。
**ST11 (kaoki_stec, O157/STEC) 以外はすべての ST 群が fimH 単一**だったため、
群名が変わるだけで比較集団は痩せない。ST11 のみ 22 株 → **H82 17 株 + H36 5 株**
に分かれる (どちらも `min_strains`=4 を満たすので系統樹は両方出る)。
他は ST1060-H27(5) / ST131-H41(4) / ST1011-H31(2) / ST2040-H38(2) /
ST641-H25(2) / ST744-H54(2) / ST998-H76(2) / ST141-H5(1) / ST95-H27(1)。
**FimTyper 未確定の検体は 0 件**だった。

**他の菌種へ広げるときは config だけでよい** — `core_snp.subtyping` に
`{species_dir: {module, result_json, field, strip_prefix, label_prefix, accept_status}}`
を足し、移行ツールを流す。**移行せずに設定だけ入れると壊れはしないが、
既存株が旧群・新規株が新群に入って比較集団が痩せる。**
**該当ファイル**: `workflow/scripts/core_snp_subtype.py` (新規・単一の真実源),
`tools/migrate_bam_db_subtype.py` (新規), `workflow/tests/test_core_snp_subtype.py` (新規),
`workflow/scripts/run_core_snp_map.py` (`store_bam_to_db(group=)`, Phase 5.5),
`workflow/scripts/run_core_snp_phylo.py` (`collect_bams(group)`, `localize_bams(group)`),
`workflow/rules/stage2_core_snp.smk`, `config/config.yaml` の `core_snp.subtyping`,
`api/services/db_manager.py` (`_split_group_dir`, scan に `st_base`/`subtype`),
`api/routers/results.py` (`/core_snp_db` の group_id, `core_snp_db_info` が群を数える),
`frontend/src/pages/CoreSnpDbBrowser.tsx`, `frontend/src/components/CoreSnpSection.tsx`

### 36. 「押しても何も起きない」= API は 200 を返すが実体が動いていない 2 パターン
2026-08-19 に利用者から「Cancel が効かない」「再実行しても Dashboard にジョブが出ない」と
2 件続けて指摘され、どちらも **HTTP は成功、UI にエラーも出ない** 無言失敗だった。
**原因は別物だが、症状の見え方が同じ**なので併記する。

#### 36.1 Cancel の停止根拠は `_ssh_process` ではなく PGID
**症状**: on-demand cgSNP の臨時ジョブ (`adhoc_20260819_152825_384b33`) で Cancel を
押しても status が RUNNING のまま。API は 200 を返す。
**原因**: `cancel_job` が `if job.status == RUNNING and job._ssh_process:` で分岐して
いた。`_ssh_process` (ローカルの asyncssh プロセスハンドル) を保持するのは
**`_run_all_batches` (レガシーのバッチ経路) だけ**で、`_run_core_snp_batch`
(on-demand cgSNP / adhoc ジョブ) は保持しない → **分岐に入らず完全な no-op**。
冒頭の account ジョブ分岐 (`sample_worker or pending_samples`) も adhoc は両方空で素通り。
**解決**: RUNNING なら必ず ①**先に** `status=CANCELLED` を確定 (kill が先だと
`_monitor_batch` の EOF 側が FAILED を書きうる) → ②`kill -TERM/-KILL -- -{job.pid}`
→ ③stale lock 解除、の順で実行する。**停止の根拠は `job.pid` (setsid で捕捉した PGID)**
であってプロセスハンドルではない。実行中の `core_snp_status` は `failed` ではなく
`cancelled` にし、`_run_core_snp_batch` / `run_core_snp_adhoc` が **CANCELLED を
FAILED に上書きしない**ようにする (従来は書き戻していた)。
**同時に塞いだ穴**: PGID 未捕捉時のフォールバック
`pkill -TERM -f 'snakemake.*{input_dir}'` は、**input_dir が汎用名のときは撃たないこと**
(`_GENERIC_INPUT_DIRS`)。adhoc cgSNP は `input_dir="results"` なので、そのまま撃つと
同一ワーカーで走る**無関係な全ジョブの snakemake に一致する**。ハング検知の
`_kill_remote_and_unlock` も同じ形だったので併せて修正。
**副作用 (承知の上)**: API の graceful shutdown (`--reload` 保存時を含む) は
`main.py` の lifespan で実行中ジョブに `cancel_job` を呼ぶので、**adhoc cgSNP も
リモートごと停止するようになった**。従来は no-op で nohup のまま生き残っていた。
**フロント**: `CoreSnpStatus` に `cancelled` を追加。**未知の status は既定で
「完了」カードに落ちる**作りなので、追加を怠ると中断が完了に見える。
PipelineTimeline では `cancelled` → `skipped` 扱い (`pending` のままだと
`coreSnpUnfinished` が真のままで後処理行が永久に完了しない)。

#### 36.2 DB から復元したジョブは `session_token` を持たない
**症状**: TAS256 で Core SNP を再実行しても **Dashboard にジョブが生成されない**。
エラー表示も無い。`/api/jobs` は total も running 数も変化しない。
**原因 (2 段)**:
1. `load_persisted_jobs` は **`session_token` を復元しない (空文字)**。API を
   リロードすると、直前の adhoc cgSNP ジョブが `status=FAILED` /
   `samples=[対象サンプル]` / `output_dir="results"` で復元される。
2. `POST /jobs/core_snp/by-samples` の Step 1 (サンプル → ジョブ対応づけ) が
   **その復元ジョブを拾い**、`run_core_snp_for_job` (= 既存ジョブに紐付ける経路。
   **新しいジョブを作らない**) に回す。さらにその中で
   `open_process(job.session_token="")` が「セッションが無い」で即失敗するため、
   数秒で cgSNP だけが failed になり **画面上は完全に無反応**。
**解決**:
- Step 1 で **`session_token` を持たないジョブを除外**する。これで Step 2 の
  NAS 参照 → **臨時ジョブ作成**に回り、生きたセッションで実行され一覧にも出る。
- `run_core_snp_for_job` は実行前に **`job.session_token` を今ログイン中の
  セッションのトークンへ貼り替える**。パスと DB override は既に `session` 側から
  取っているのでトークンだけで文脈が揃う。**復元ジョブだけの話ではない** —
  再ログイン後に古いジョブから再実行しても同じ無言の失敗になるため必須。
- 併せて `asyncio.create_task(...)` の戻り値を捨てていた 6 箇所を `_spawn_bg()`
  (強参照保持) に変更。GC でタスクが消えると、これも同じ「無言で何も起きない」になる
  (runner 側が `_spawn` を持つのと同じ理由)。
**未対応 (同じ構造が残っている)**: Bakta / plasmid cluster の後追い実行も
インメモリ JobRecord を実行文脈として再利用するので、復元ジョブ・失効トークンで
同じ失敗をしうる。**インメモリ JobRecord を実行に使う箇所は、必ず
`session_token` が生きているかを疑うこと。**
**該当ファイル**: `api/services/snakemake_runner.py` (`cancel_job`,
`_GENERIC_INPUT_DIRS`, `_kill_remote_and_unlock`, `_run_core_snp_batch`,
`run_core_snp_adhoc`, `run_core_snp_for_job`), `api/routers/jobs.py`
(Step 1 のフィルタ, `_spawn_bg`), `frontend/src/lib/api.ts` (`CoreSnpStatus`),
`frontend/src/components/CoreSnpSection.tsx`, `frontend/src/components/PipelineTimeline.tsx`

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

### 37. Illumina ショートリード対応 — 骨格はあったが未実行、露出した穴は 3 つ
**前提**: 短鎖リードの骨格 (classify_input の R1/R2 検出、SPAdes ルール、
`get_input_fasta` の分岐、fastq アップロード、UI のモード表示、`NODE_N` の
contig 名正規化) は v2.0 で実装済みだったが、**一度も実行されていなかった**
(NAS 全 7 アカウント 515 検体で `assembly/short_read/` は 0 件)。
2026-08-19 に SRR12628569 (E. coli O157) を `TAS002_Illumina` として初投入した。

**アセンブリ自体は実用水準**: 74× / 191 contig / N50 124 kb / CheckM2 完全性 100.0・
汚染 0.07。同一分離株の ONT 版 (`TAS002_ONT`) と **ST11・FimH82・O157:H7・
STEC/EHEC・stx2c・MOB cluster AA345 まで完全一致**した。QUAST の ONT 較正閾値
(N50<10 kb / contigs>500 で WARN) も素通りするので、閾値の作り直しは急がない。
molecule 判定も環状性の証拠ゼロで status=PASS / `genome_size_ratio 0.972` /
判定不能は 37 contig (全体の 3.2%) に収まり、断片化による劣化は軽微だった。

**実測で分かった SPAdes の性質 (思い込みを 3 つ壊した)**:
- **`--isolate` はリード補正を行わない** (ログ: `Mode: ONLY assembling (without
  read error correction)`)。`--only-assembler` は不要で、補正済みリードの残骸も出ない。
- **既定メモリ上限は「実機の RAM 全量」** (honban で `Memory limit (in Gb): 216`)。
  250 GB 固定ではない。**1 ワーカーで N サンプル並走させると各々が RAM を
  丸ごと自分のものだと思い込む** ので `-m` の頭割りが要る
  (`spades_mem_divisor` を `--config` で渡す。#25 の `core_snp_phylo_jobs` と同じ形)。
- **`cov_` は k-mer 被覆であって read 被覆ではない。** 実測 read 74× に対し
  ヘッダは `cov_42.4` (K55 換算で約 0.60 倍)。**低被覆フィルタの閾値を read 被覆の
  感覚で置くと 2 倍近く外す。** shovill の `--mincov 2` と同じ k-mer 基準で置くこと。
- `spades_output/` は **84 MB が NAS までアーカイブされていた** (検体 203 MB の 41%)。
  成功パス末尾の `rm` しか無く EXIT trap が無かった (#project_assembly_intermediate_fastq_leak
  と同型)。`assembly_graph_with_scaffolds.gfa` だけは残す価値がある —
  `assembly/short_read/assembly_graph.gfa.gz` に置けば `results.py` の
  assembly-graph-gfa は既に `("long_read","short_read")` を走査するので **API 改修なしで**
  既存の GfaGraph ビューアが使える。

#### 37.1 プラスミド照会が無言で消える (最重要)
**症状**: 同一分離株の ONT 版と Illumina 版で、アウトブレイク照会の結果が正反対になった。
ONT は AA345 で **160 件マッチ / `trigger_layer_b: true`**、Illumina は
**同じ AA345 を検出しているのに `num_plasmids: 0` / `num_with_matches: 0`**。
**原因**: `plasmid_outbreak.require_circular` (既定 true) で短鎖リード contig は
1 件も登録されない → `check_plasmid_outbreak.py` は **登録した uid を起点に**
DB を引く設計なので照会が 1 件も走らない → 「マッチ無し」として正常終了。
しかも `num_skipped: 0` で**「プラスミドはあったが見送った」痕跡すら残らない**。
**解決**: `_read_contig_report()` が `(登録対象, 見送り)` を返し、`registration.json` に
`withheld_clusters` を残す。`check_plasmid_outbreak` は `non_circular` で見送った
クラスタも **read-only で照会**する (`known_vector` / `variant_segment` は
「プラスミドとして扱わない」判断そのものなので照会しない)。
**`trigger_layer_b` は登録済みのマッチだけで決めること** — Layer B.1 は DB 内 FASTA を
母集団に走るので、DB に居ないプラスミドで起動しても当の検体がクラスタに入らない。
UI と HTML には「DB 未登録・照会のみ」を明示する。
**検証**: Illumina は 0 → **184 件マッチ**、ONT は構造上 `registered` キー追加のみで不変。

#### 37.2 cgSNP が「完了」と表示される (#28 の UI 版)
`core_snp_phylo` は skip / insufficient / failed でも `core_snp_result.json` を書いて
exit 0 する。ところが API は `MODULE_CHECK_MAP` の**ファイル実在だけ**を見ており、
`core_snp` は `_OPTIONAL_MODULE_FILES` (完了後に status を読むリスト) に**入っていなかった**。
その結果、short_read 検体 (cgSNP は input_mode で SKIPPED) が UI で緑チェックの
「完了」になっていた。`_OPTIONAL_MODULE_FILES` に追加し、ポーラが status を読んで
`skipped`/`failed`/`completed` を出し分けるようにした。
**読み出しは `sftp_*` ではなく既存接続への `exec_command` で行うこと** —
SFTP 経路は失敗時に接続を張り直し、`_poll_sample_module_status` の docstring どおり
監視ストリーム (open_process) を巻き添えにしうる。

#### 37.3 cgSNP の Illumina 対応は「引き算」でできる
ONT 経路の Phase 1-4 (fastplong → DeChat → wgsim) は要するに
**「長鎖リードから擬似ペアエンドを作る」**工程なので、Illumina では丸ごと不要。
fastp をかけて Phase 5 (stringMLST) 以降にそのまま渡せばよい (stringMLST も BWA も
本来この形の入力を想定している)。**ただしマッパーは分けること** —
`bwa bwasw` は長鎖向けでペア情報も捨てるため 150 bp には不適 (`bwa mem` を使う)。
**ONT 側は bwasw のまま変えないこと**: 既存 BAM DB が全て bwasw 由来で、
差し替えると同一 ST 群の BAM 再構築と再検証が要る (#23)。
ダウンサンプルは **R1/R2 を同一シード (`seqkit sample -s 42`) で引いてペアを保つ**。
**BAM DB は ONT と同じ群に同居させる** (ユーザー決定) が、`metadata.json` /
`mapping_info.json` / `core_snp_result.json` に `platform` を必ず記録する。
**platform キーの無い旧登録は ONT。**
理由: 全検体が同一プラットフォームならその系統的エラーは全 BAM に共通に乗るので
距離計算では相殺されるが、**混在すると相殺が効かず跨ぐペアの距離だけが膨らみうる**。
UI (`CoreSnpSection` / `CoreSnpDbBrowser`) に混在を明示する。
**較正値の実測 (2026-08-20): `TAS002_ONT` × `TAS002_Illumina` = 0 SNP**
(コアゲノム 4,302,461 bp / 168 株の群)。両者の距離行列の行は他の全株に対しても
完全に一致し、次に近い株は 18 SNP 離れている。**同居させる決定の前提は実測で
裏付けられた**が、これは DeChat 補正済み ONT R10 を十分な被覆で読んだ n=1 の値。
低被覆 ONT でも 0 である保証は無いので、ペアが増えたら再確認すること。

#### 37.4 その他
- **hybrid は名前負けしている。** 両方あると `mode=hybrid` になるが
  `get_input_fasta` は SPAdes contigs を返すだけで**長鎖リードは捨てられる**。
  真の hybrid アセンブラは未導入。ルールのログに明記した (ユーザー決定: 現状維持)。
- **リード QC** (`per_sample_report` の `read_qc` セクション) を追加。
  `fastp.json` を **params 渡し**で読む (circularity.json と同じ理由 = DAG を変えない
  = ONT 検体に影響しない)。推定被覆 = トリム後総塩基 ÷ `genome_size_map`。
  **fastp.json が無いモードは `not_applicable` で返し 0x とは書かない** (#28)。
- `input/contigs.fasta` は NAS 上で dangling symlink になる (#17)。ONT と同じ挙動で
  ダウンロード API のフォールバックが効くので新規の問題ではない。
- **phylo は株数に強くスケールする。** 実測 2026-08-20: `Ecoli/11_H82` 群 168 株で
  **`core_snp_phylo` だけ 4 時間 50 分** (ジョブ全体 5h18m のうち、レポート生成までは
  28 分)。#23 の 12.6 分は 22〜28 株のときの値。`core_snp.max_strains: 200` なので
  群が育つとそのまま効く。mpileup (全位置で N 個の BAM を読む)・ClonalFrameML・
  RAxML (`-f a -N 1000`) がいずれも株数に効く。**Illumina 対応とは無関係。**
  大量再実行 (例: [[project_cgsnp_phylo_nameerror_st]] の 250 検体) を計画するときは
  先に max_strains を決めること。
- **DB の `jobs` 行は実行中の状態を持たない。** `_persist(job)` はサンプル完了時と
  ジョブ確定時にしか呼ばれないので、走行中は `status='queued'` / `started_at=NULL` のまま。
  UI が「実行中」を出せるのはインメモリの JobRecord を読んでいるから。
  **DB をポーリングして進捗を追おうとしないこと。** 走行中に API がリロードされると
  そのジョブは `queued` のまま復元され、#36.2 の「無言で何も起きない」条件が揃う。
**該当ファイル**: `workflow/rules/stage1_spades_assembly.smk`,
`workflow/scripts/filter_spades_contigs.py` (新規), `workflow/rules/stage2_core_snp.smk`,
`workflow/scripts/run_core_snp_map.py` (`run_fastp_paired`, `run_bwa_mapping(platform=)`,
`store_bam_to_db(platform=)`), `workflow/scripts/run_core_snp_phylo.py`,
`workflow/scripts/register_plasmids_to_db.py` (`_read_contig_report` の 2 値返し),
`workflow/scripts/check_plasmid_outbreak.py`, `workflow/scripts/per_sample_report.py`
(`_build_read_qc_section`), `workflow/rules/stage4_aggregate.smk`,
`api/services/snakemake_runner.py` (`_sweep_intermediates_cmd`, `_read_core_snp_status`,
`_CORE_SNP_MODES`, `spades_mem_divisor`), `api/services/db_manager.py`,
`api/routers/results.py`, `config/config.yaml` の `assembly.short_read` /
`core_snp.fastp_*`, frontend (`SampleDetail` / `CoreSnpSection` / `CoreSnpDbBrowser` /
`PlasmidProfileSection` / `htmlExport` / `api.ts`)

### 38. 検証スクリプトの既定値を本番 config と一致させること — 存在しない問題を 2 日追った
**事故 (2026-08-21〜22)**: 同一分離株を ONT と Illumina で読んだ 79 ペアの cgSNP 距離が
**中央値 5〜6 SNP** 離れており、原因究明に丸 2 日を費やした。置換スペクトル解析
(C↔G 1.8% = 低被覆アーティファクトではない)、メチル化モチーフ照合
(Dcm/Dam 一致 0/311 = 背景以下)、反復配列の同定 (不一致サイトの 73.6% が反復領域 =
ランダムの 9.5 倍、74.2% が 500bp 以内に集中 = 同 26 倍) まで進め、
**反復領域マスクを実装**して中央値 5 → 1 まで改善させた。

**ところが本番設定で測り直したら、マスク無しで中央値 0・79 組すべて 5 SNP 以下だった。**

**真因**: 検証に使った `cgsnp_subset.py` の既定値が `--varscan-min-freq 0.9` で、
**本番 config は 0.01** だった (`core_snp.varscan_min_freq`)。
`min_freq 0.9` は「90% が同じ塩基なら確信して呼ぶ」ので、反復領域で誤マップが
多数派を占めた位置を**そのままコンセンサスに入れる**。本番の 0.01 は同じ位置を
ヘテロ (`/`) と判定してコアから除外するため、問題が最初から出ない。
`varscan_min_coverage` も本番 8 に対し検証は 10 だった。

| 条件 | コア率 | ペア距離中央値 | 0 SNP |
|---|---|---|---|
| **本番 (mc8, f0.01)** | **75.2%** | **0** | **51/79 組** |
| mc10, f0.9 | 65.6% | 5 | 0 組 |
| mc5, f0.9 | 85.1% | 8 | 0 組 |
| mc10, f0.9 + 反復マスク | 63.3% | 1 | 39 組 |

**教訓**:
- **解析ツールを新規に書くとき、パラメータの既定値を自分で決めないこと。**
  必ず `config.yaml` の対応する値と一致させる。`cgsnp_subset.py` /
  `pairwise_cgsnp.py` の既定は 8 / 0.01 に修正済み (理由もコードに書いた)。
- **本番と違う条件で出た数値を「本番の問題」として報告しないこと。** 今回は
  ユーザーに 4 条件の比較表まで示して本番化の承認を得る直前まで行った。
  実装 (反復マスク) 自体は正しく動いたが、**解こうとしていた問題が存在しなかった**。
- 調査の過程で使った診断ツールは有効だった (置換スペクトル / 位置の再現性 /
  モチーフ濃縮)。**手法ではなく前提条件の確認が抜けていた。**
- `varscan_min_freq 0.01` は「反復領域を自動的に除外する仕組み」として
  既に機能している。**この値を上げてはいけない。**

**残した成果物** (既定 `None` / 未使用で本番の挙動は不変):
`workflow/scripts/build_repeat_mask.py` (k-mer 一意性マスク生成、`is_masked` に
境界処理を集約)、`run_core_snp_phylo.run_mpileup_consensus(masked_positions=)`。
将来 `min_freq` を上げる場面があれば使える。import 失敗時は WARN を出して
マスク無効に落ちるので、同期ずれで cgSNP が全滅することはない。

**副産物として確定したこと**:
- クロスプラットフォーム (ONT×Illumina) の同一分離株は**本番設定で 0〜2 SNP**。
  79 組中 51 組が 0 SNP、10 SNP 超は 0 組。#37.3 の「較正値 = 0 SNP」(n=1) は
  n=79 で追認された。
- `cgsnp_subset.py` (新規) で bam_db の**部分集合**・プラットフォーム別の
  cgSNP 解析ができる。`run_core_snp_phylo` の関数を import するので手順は同一。
- **2 株だけの比較は ClonalFrameML が走らない** (`if n_strains >= 3`)。
  ペア距離は「ペアだけで測り直す」のではなく**群単位の距離行列から読む**こと。

### 39. dorado の中間 BAM (dorado_runs) は完了時に消す — 下流が読むのは fastq
**背景 (2026-08-28)**: `_process_single_pod5` は 1 pod5 ごとに basecall → demux し、
demux BAM を NAS の `dorado_runs/{job_id}/demux/chunk_NNN/` へコピーする。
**消す処理が無かった**ため実測で **NAS 全 4 アカウント合計 284 GB**
(kaoki_stec 219 GB / toho_micro_id_bsi 37 GB / kojima 16 GB / toho_omori 12 GB、
41 ジョブ) が積み上がっていた。

**消してよい根拠**: 下流 Snakemake が読むのは
`dorado_samples/{job_id}/{sample}/{sample}.fastq.gz` の方
(`_measure_barcode_coverage_inner` が BAM から生成し、そのまま入力パスに置く)。
下流の自動再投入 (`downstream_max_retries`) も **fastq を再利用する**ので
BAM は要らない。完了後に BAM を読む API も無い (`worker_demux_dirs` を使うのは
coverage 計測だけ = 完了前)。

**実装**: `DoradoRunner._cleanup_run_dir()` を `_run_job` の末尾
(status=completed の後) で呼ぶ。`config.dorado.cleanup_intermediate_bam`
(既定 true) で無効化可。
- **削除するのは completed のときだけ。** failed / cancelled は原因調査のため
  残す (例外経路には呼び出しを置かない)。
- **run_dir の形を確認してから消す** — `/{output_subdir}/{job_id}` で終わること、
  絶対パスであること、job_id が `[A-Za-z0-9._-]+` であること。パス組み立てが
  将来変わっても無関係なディレクトリを `rm -rf` しないため。
- 削除**前**に件数とサイズを測り `CLEANUP:<件数>:<バイト数>` を stdout に出して
  ジョブログに載せる。跡地に `CLEANED.txt` を残す
  (**「消えた」と「消した」を区別できるようにする** — #28 と同じ趣旨)。
- 失敗しても例外を投げず WARNING に留める (解析結果には影響しないため)。
- `wc -l` の出力は環境によって空白が付くので `tr -d '[:space:]'` で潰すこと
  (ログに `demux BAM        2 件` と出る)。
**既存の滞留分**: `tools/cleanup_dorado_intermediates.py` (dry-run 既定)。
**`dorado_samples/` の fastq が 1 つ以上あるジョブだけ**を対象にする
(fastq 化まで到達していない = やり直しの余地があるジョブを消さないため)。
pod5 と fastq には触らない。`CLEANED.txt` の有無で冪等。
**該当ファイル**: `api/services/dorado_runner.py`
(`build_cleanup_command`, `_cleanup_run_dir`, `_run_job`),
`tools/cleanup_dorado_intermediates.py` (新規),
`config/config.yaml` の `dorado.cleanup_intermediate_bam`

### 40. フロントの `.catch(() => null)` は #28 の UI 版 — 距離マップが 10 日間死んでいた
**症状 (2026-08-28)**: 24266 の Genetic Distance Map (DCJ-Indel MST) が、
セクション見出し・プラスミドセレクタ・表示範囲トグルまでは出るのに
**本体だけが何も描かれない**。エラー表示もローディング表示も無い。

**「無言」の理由 = フロントの握り潰し**。`PlasmidProfileSection.tsx` の
距離マップ用 `useQuery` が `queryFn: () => fetch...().catch(() => null)` になっており、
**失敗が「成功 (値 null)」に化けていた**。結果 `isLoading=false` /
`data=null` / `isError=false` の三拍子が揃い、`{distanceQ.data && <PlasmidDistanceMap/>}`
が何も返さないまま**エラー分岐にも入らない**。
`|| true` で外部ツールの終了コードを捨てるのと同じ構造で、**#28 の UI 版**。
- **空欄 = 取得失敗であって singleton ではない。** 真に単独クラスタなら
  `PlasmidDistanceMap` が `No related plasmids — singleton cluster` を出す。
  **この文言が出ていない空欄は必ず失敗**と読むこと。
- **`--reload` の裏で 500 が出続けていても画面は静か**なので、
  発見が「なんで出ないんでしたっけ」という会話に依存していた。

**真因 = `_parse_int` の定義だけが消されていた** (`NameError`)。
`git log -S_parse_int` で `fc2271b` (2026-08-18, 「一覧ロードを 14.6 秒 → 3.67 秒に」)
がヘルパ定義を削除しており、`get_plasmid_distance_map` の呼び出し 1 箇所だけが
取り残されていた。**発火条件が絞られているせいで気づけない**:
この行は **DB `index.tsv` の行が `plasmid_clusters_merged.json` に無いとき**しか通らない。
一方アカウントセッションは router が `db_path = session.group_plasmid_db_path` を
**常に強制**するので DB index ループは必ず回る → index (151 行) と merged (148) が
ズレた瞬間に 500。つまり **8/18 以降、アカウント経由の距離マップは実質全滅**していた。
- **未使用に見えるヘルパを消すときは呼び出し側を grep すること。** 静的検査は
  入っていない (pyflakes/flake8 とも未導入)。**`python -c` の AST 走査で
  F821 相当は数秒で回せる** — ただしクロージャの外側スコープ参照が偽陽性で出る。
- `_parse_int` は **`index.tsv` が `csv.DictReader` で全列を文字列で返す**ために要る。
  `size_bp` を素通しするとフロントの `size_bp / 1000` が壊れる。
  **空欄・非数値は 0 ではなく `None` (= 不明)** にすること (0 は「サイズ 0 bp」と読める)。

**入れた可視化 (3 段)**:
1. `api.ts` に **`ApiError` (status 付き Error サブクラス)** を追加し、
   `request()` / `fetchDownload()` / アップロード 2 箇所の throw を統一。
   **`message` は従来どおり FastAPI の `detail`** なので既存の表示文言は不変。
2. 距離マップの `.catch(() => null)` を削除し、`isError` 時に理由付きの警告ボックスを出す。
   **404 (= クロスアイソレート解析が未実行) と それ以外 (= 読み取り失敗) で文言を分ける**
   — 対処が違うため。末尾に `HTTP <code> · <detail>` を等幅で必ず出す。
3. `/plasmid_distances` の router で parser 呼び出しを try/except し、
   **実例外を `detail` に載せて 500 を返す** (`logger.exception` も出す)。
   `api/main.py` に例外ハンドラが無いので、これが無いと素の
   `Internal Server Error` になり **404 との区別しかできない**。
**react-query v5 の注意**: 「初回ロード中」は `isLoading` で見ること。
**`isPending` は `enabled: false` でも true** になるので、
中心プラスミド未選択のときに「Loading…」が出っぱなしになる。

**このカードだけが単独で失敗しうる理由**: SampleDetail の他のカードは
サンプル自身の report JSON 由来だが、**距離マップだけがバッチ階層の
`results/plasmid_clusters/` を SFTP で読む**。他が全部出ていても、
ここだけ死ぬのは構造上ありうる (切り分けの起点にすること)。
**該当ファイル**: `api/services/result_parser.py` (`_parse_int` 復活),
`api/routers/results.py` (`get_plasmid_distance_map` の try/except),
`frontend/src/lib/api.ts` (`ApiError`),
`frontend/src/components/PlasmidProfileSection.tsx` (握り潰し除去 + エラー表示)

### 41. 距離マップに疫学の軸 (菌種 / 分離日) を載せる — Phase 1
**動機**: Genetic Distance Map (DCJ-Indel MST) はノードに `plasmid_uid` と
carbapenemase しか出しておらず、**carbapenemase が空のクラスタでは完全に無地**
だった。実測 toho_micro_id `AA002` は 34 プラスミド / **14 菌種** (Klebsiella 6種・
Enterobacter 4種・Citrobacter 2種・E. coli・S. marcescens) がすべて 87.3 kb の
IncL/M で、しかも**中心との DCJ=0 が 6 菌種にまたがる**。これは
「同じプラスミドが菌種を超えて広がっている」= **cgSNP 系統樹では原理的に見えない
このパネル固有の情報**なのに、画面上は灰色の丸が並ぶだけだった。

**データは既にあった (新規計算ゼロ)**:
- **菌種・ST** = `results/{sample}/report/{sample}_summary.json` (サマリー行キャッシュ)。
  `_rows_via_remote` に相乗りするので **SSH 1 コマンド**で 184 ノードでも済む。
  実測 kaoki_stec は DB プラスミドの 222 サンプル全件にキャッシュがある。
- **分離日** = アカウント DB の `sample_metadata` (ルータで引くだけ、I/O ゼロ)。
  実測 kaoki_stec は 259 件登録済みで、DB プラスミドの 222 サンプルと **100% 重なる**。
- **地域は存在しない** (Phase 2 で `sample_metadata` に列追加が要る)。

**踏んではいけない罠**:
- **`by_cluster/*.meta.json` の `mash_neighbor_identification` を菌種に使わないこと。**
  あれは「そのプラスミドの mash 最近傍 (公共 DB エントリ) の宿主」であって、
  この検体の同定結果ではない。名前が紛らわしく、そのまま使えてしまう。
- **`index.tsv` の `registered_at` は解析日**であって分離日ではない。
- **「取得失敗」を「該当なし」に化けさせない** (#28 / #40 と同じ)。
  `host_metadata_status` / `isolation_date_status` を返し、UI は
  「菌種 不明」「分離日 未登録」と「取得失敗」を書き分ける。
- **色分け軸は固定にできない。** 群ごとに効く軸が違う — kaoki_stec `AA345` は
  184 個すべてが E. coli ST11 (菌種では塗り分かれない) で分離日が 5.5 年に分散、
  toho_micro_id `AA002` は 14 菌種だが分離日が未登録。既定は**データを見て決める**
  (2 菌種以上 → 菌種 / 2 年以上 → 分離年 / それ以外 → 出所)。
- **カテゴリ色は 3 枠まで。** 力学配置は任意の 2 ノードが隣り合うので all-pairs で
  CVD 検証が要る (`#2a78d6` / `#eb6834` / `#1baf7a` は deutan ΔE 9.2・normal ΔE 24.0
  で通過)。4 色目以降は通らないので**「その他」に畳み**、内訳は凡例注記と一覧表が持つ。
  14 菌種を 14 色にしないこと。**分離年は順序のある量なので単一色相の明→暗ランプ**
  (5 段) を使う — カテゴリ色を年に割り当てない。
- **直接ラベルは 1 菌種 1 個だけ。** 全ノードに付けると 34 ノードで完全に潰れる。
- **`plasmid_uid` をそのままノードラベルにしない。** `{sample}__{cluster}` なので
  同一クラスタを見ているときはクラスタ部分が全ノード共通 = 雑音
  (実測 AA667 の 52 ノードが全部 `TASxxx_ONT__AA667`)。表示名だけにし、
  別クラスタのノードにだけクラスタ ID を添える。**表とツールチップでは
  内部 ID を併記する** (#18)。
- **`useSampleAliases()` の戻り値そのものを d3 effect の依存にしないこと。**
  毎レンダー新しいオブジェクトなので力学配置が毎回リセットされる。中身の
  `aliases` マップ (useSyncExternalStore のスナップショット) を依存にする。
- **「中心との DCJ」を MST 経路長で代用しないこと。** 直接ペアが未計算のときは
  「未計算」と出す (別の量を同じ列に混ぜない)。

**入れたもの**: 1 文サマリ (「34 プラスミド · 14 菌種 (…) · 分離日 …」+ 複数菌種の
警告)、色分け軸セレクタ (菌種 / 分離年 / 出所)、出所はリング様式・carbapenemase は
赤ハローへ移動、菌種をまたぐエッジのツールチップ明示、**メンバー一覧表**
(サンプル / 出所 / 菌種 / ST / 分離日 / サイズ / rep / carbapenemase / 中心との DCJ、
ソート可)。表は 34 ノードの `AA002` で「同一 IncL/M が DCJ=0 で 6 菌種に分布」を
一目で読ませる。**HTML エクスポートは距離マップを出力していない**ので今回は対象外
(一覧表だけなら移植可能)。
**該当ファイル**: `api/services/result_parser.py` (`get_plasmid_distance_map` の
宿主メタデータ付与), `api/routers/results.py` (分離日の付与),
`frontend/src/lib/api.ts` (`host_species` / `host_st` / `isolation_date` +
2 つの status), `frontend/src/components/PlasmidDistanceMap.tsx`

### 42. 近いプラスミド同士の構造比較 (Genetic Distance Map からのペア比較)
**動機**: 距離マップは「どれとどれが近いか」しか出さず、**なぜ DCJ=3 なのか**
(挿入か / 反転か / 反復のコピー数差か) が見えなかった。エッジ・ノード・
メンバー一覧の行から 2 本を選び、線形シンテニー + 遺伝子トラックで並べる層を足した。

**判定と座標計算は `workflow/scripts/compare_plasmid_structure.py` のみが行う。**
frontend (`PlasmidStructureCompare.tsx`) は描くだけ (#19 の二重化事故の再発防止)。
API はこのスクリプトを **base64 で送ってワーカーで実行する** (`_rows_via_remote` と
同じ idiom = workflow/ の同期を当てにしないので版ずれが原理的に起きない)。

**エンジンは blastn -subject。pling ブロックは補助層に留めること。**
pling は既に全ペアのブロック分解を座標付きで出している
(`plasmid_clusters/pling/unimogs/{batch}_align.unimog` と `_map.txt`。符号付き整数列で
反転も入っている。中央値 10 ブロック/ペア、DCJ=0 なら 1 ブロック) が、
**`plasmid_clusters/` は最後の on-demand 実行で丸ごと上書きされる**。
実測 2026-08-29: kaoki_stec は最後が manual 3 サンプル実行だったため
`all_plasmids_distances.tsv` が **1 ペアだけ**で、DB 373 本・距離マップ 184 ノードの
AA345 にブロックが**存在しない**。pling だけを描画源にすると一番見たいクラスタで
無言の空欄になる (#40)。**pling が無いことは「差が無い」ではない** ので
`available=false` + 理由を必ず返して UI に出す。
- blastn は py39 に既存 (`config.paidb.blast_path`)、`-subject` で DB ビルド不要
  (`screen_known_vectors.py` と同形)。実測 0.3〜1.2 秒/ペア (76〜390 kb)。
- 閾値は **pling と同じ値**にしてある (`identity 80.0` / `length 200`。pling.log の
  `identity_threshold` / `length_threshold`)。**自分で決めないこと** (#38)。
- 同一クラスタ外のペアは megablast だと拾えないので、被覆 30% 未満なら
  **dc-megablast で引き直し、どちらで引いたかを出力に残す** (#29.1)。

**座標は全部そのまま乗る (実測で確認済み)**: `plasann/plasmid_contigs/{cid}.fasta` /
`db/plasmid_outbreak/by_cluster/{cid}/{uid}.fasta` /
`plasmid_clusters/all_plasmids/{uid}.fasta` の 3 つが **md5 一致**、かつ
`assembly/long_read/contigs.fasta` の当該 contig とも一致する。したがって
AMRFinder / PlasmidFinder / MEFinder の contig 座標はオフセットを足すだけで乗る。
PlasAnn だけは**プラスミド単位 FASTA 上の座標**なので、単位 FASTA の contig 並びが
一致することを**実物で確かめてから**使う (一致しなければ出さない — #22)。

**原点ズレは避けて通れない**。dnaapler で repA 起点に回転済みなのは
**395 本中 279 本 (71%) だけ**で、残り 116 本は未回転。線形に並べると原点差が
巨大な転座に見えるので、最長の共線 HSP を錨に **query の「描画座標だけ」** を
回転/反転する。**配列・contig 名・座標そのものは絶対に書き換えない** (#21/#22)。
適用したかどうかと錨の長さは出力に残し UI に出す。原点をまたぐ HSP と遺伝子は
**2 片に割って両方返す** (片方だけ描くと遺伝子が消えたように見える。実測
17575__AA002 の `aadA22` が該当)。

**共線性はオフセットの一致率で測ってはいけない。** 1 か所の挿入で下流のオフセットが
全部ずれ、実際には共線なのに「大規模再配列」と誤報する (実測 17570 vs 17575 は
14 kb の挿入 1 か所で 0.64 まで落ちた)。**枠を当てた後に順序で測る**
(`collinear_fraction` = 長さ加重 LIS)。挿入/欠失は共線のまま、転座と反転だけが落ちる。

**多 contig プラスミドは pling が 1 配列しか見ていない。** 実測 11045__AA739 は
390,789 bp のうちブロック座標が 384,222 までしか無い (6,568 bp の linear contig が
落ちている)。連結座標軸で描き、contig 境界を図に明示し、警告に出す。
多 contig の query は**原点合わせをしない** (どこが原点か定義できない)。

**キャッシュは `{db_path}/_structure_cache/` に置く** — `plasmid_clusters/` に置くと
再実行で消える。有効性は**入力 FASTA の size + mtime** で判定すること
(`plasmid_uid` は `{sample}__{cid}` なので**再解析しても uid が変わらないまま中身が
変わる**。#26 の BAM キャッシュと同じ罠)。許容は 1 秒未満。実測 1.2 秒 → 0.07 秒。

**採らなかった選択肢**: pling の `--visualisation` は**ネットワーク図**であって
構造比較図ではない (今の MST の下位互換)。pling 全体の再実行は 148 プラスミドで
8 分・184 なら 1.5〜2 時間でクリック応答に使えない。clinker / pyGenomeViz は
新規 env が要るうえ独立 HTML / 静止画で、エイリアス層 (#18) にも既存 UI にも乗らない。

**中心アンカーのスタック (中心 1 本 vs 近い順 N 本)**: 同じエンドポイントで
`query_uid` を繰り返すと `plasmid_structure_stack/1` が返る (schema で見分ける)。
ペアごとの計算は `compare()` をそのまま使い、**ペア表示とキャッシュを共有する**
ので、片方で開いた組は他方でも即時になる。
- **行はリボンではなく「中心上の位置の色」で塗る** (Mauve と同じ考え方)。10 行に
  リボンを引くと毛玉になる。色は順序のある量なのでカテゴリ色ではなく知覚的に単調な
  ランプ (viridis) を使う (#41 と同じ方針)。
- **ブロック 1 個を 1 色で塗らないこと。** DCJ=0 のペアは全長が 1 ブロックになるので
  中点の色で塗ると行全体が単色になり、**「中心と同じ並びである」という一番読ませたい
  情報が消える**。ブロック内部も位置に応じて塗り分けると、同一なら中心のグラデーションが
  そのまま再現され、反転していれば**グラデーションが逆向きに出る** (実測 19403__AA002 の
  52 kb 反転)。サブ矩形は隣と 0.75px 重ねること (アンチエイリアスの白い縞が模様に見える)。
- 相手の並び順は**呼び出し側 (frontend) が決める**。DCJ が計算済みのものを優先し、
  未計算は後ろへ回す (「遠い」ではなく「分からない」なので上位に混ぜない)。
- **FASTA を解決できなかった相手も行として残す** (赤い破線)。黙って落とすと
  「並べられなかった」が「差が無い」に見える (#28)。
- 上限 `MAX_STACK_QUERIES=24` (1 ペア約 1 秒 × N)。距離マップは 184 ノードになり得る。

**一致率は「色の濃さ」に載せる。不透明度に載せてはいけない** (Easyfig と同じ分担で
**向き = 色相 / 一致率 = 濃さ**)。以前は不透明度に載せており、同一クラスタの
プラスミド (実測 97〜100%) が 0.51〜0.55 の差にしかならず目で読めなかったうえ、
重なったリボンで不透明度が合成されて**実在しない濃淡**が見えていた。
- 既定のスケールは engine の下限 (80%) 〜 100% 固定 — **比較同士を見比べられる**。
  ただし同一クラスタでは上位 1/4 に飽和するので、実データの範囲へ引き伸ばす
  トグルを併置する。**凡例には必ず端点を数値で出すこと** (範囲が動くので、
  数値が無いと「濃い = 高い」以上のことが読めない)。
- 「同名マーカーの対応」(clinker 風) は**配列の相同性ではなく名前の一致**。
  clinker はタンパク質のアラインメントで相同性を出すが、こちらにあるのは
  検出済みマーカーの名前だけ。ラベルとツールチップに必ずそう書く。
  位置の移動 (実測 blaIMP-1 が 9 kb → 89.8 kb) を読むには十分役立つ。

**多本比較でも blastn のリボンは出せる。「中心のバーを段ごとに繰り返す」こと。**
中心 1 本から N 本へリボンを引くと他の段を横切って毛玉になるので、**1 段 1 ペア**の
段組にする (Easyfig の多段比較と同じ形)。データは元々「中心 vs 各相手」の星形
なので、この段組が計算内容とそのまま一致し、**合成も推定も要らない** —
スタックの応答には既に全ペアの segments / frame が入っているので、
追加の計算はゼロ。実測 19403__AA002 は 4/4 セグメントが反転しており、
段組にした瞬間に「1 段だけ全部オレンジ」として読める (行/円環では読み取れなかった)。
- **一致率スケールは全段で共通にすること。** 段ごとに決めると、同じ濃さが段に
  よって違う一致率を意味することになり必ず誤読される。
- 相手同士を直接比べた図ではないことを注記に明記する (chain 型ではなく星型)。
- 色とリボン形状は `lib/plasmidStructureColors.ts` に集約 — ペア表示と段組で
  別々に持つと「同じ一致率が図によって違う濃さ」になる。

**円環表示 (BRIG 風) は直線表示の置き換えではなく併用**: 円環は**中心の座標を角度に**
するので全リングを同じ角度で比較でき「どこが欠けているか」が読める代わりに、
**相手だけが持つ配列を原理的に描けない**。直線は各相手自身の座標に描くので
そちらが見える。UI に両方置き、円環側にはこの制限を明記する。
- 角度が位置を表すので、色は**一致率**に使う (BRIG と同じ)。ただし同一クラスタの
  プラスミドは一致率がほぼ飽和してリングが全部同じ色になるため、**リング番号を
  12 時の位置に振って**下の凡例リストと紐付ける。
- **番号の下に必ず地 (濃い円) を敷くこと。** 12 時の位置がその相手に無い領域だと
  白抜き文字が薄い地に乗って消える (実測 17575 の番号 1 が消えた)。

**HTML 書き出しは「描画済みの DOM を複製する」こと。** 図の幾何を書き出し用に
書き直すと、片方だけ直したときに画面と出力が食い違う (#19 と同型で、図の場合は
「報告書に載せた図だけが古い」という形で表面化する)。操作用の要素には
`data-export-skip` を付けて複製時に落とし、CSS 変数は文書の外で解決されないので
現在の計算値へ焼き込む。出力は単体で開ける 1 ファイル。
**図だけが独り歩きする**ので、DCJ は別計算であること・原点を回している場合が
あること・「共有していない」は遺伝子が無いことを意味しないこと・取得できていない
検査結果は図に出ないことを、注記として必ず添える。

**任意ペアの比較は最初から可能で、制約は選択 UI だけだった。** 構造比較は
plasmid_uid さえあれば走る (FASTA は命名規約で DB から解決する) が、距離マップは
「中心と同じクラスタ / community」しか出さないので、そこからは**無関係な
プラスミド同士を選べない**。`PlasmidComparePickerDialog` でグループ DB 全体から
基準・相手を選べるようにした。
- そのために `/api/results/plasmid_db` に**個々のプラスミド** (`plasmids[]`) を
  足した。従来はクラスタ集計しか返しておらず plasmid_uid が取れなかった。
  実測 150〜373 行で 29〜76 KB。
- **DB 未登録のプラスミドを取りこぼさないこと。** 環状に閉じていない contig は
  DB に載らない (`require_circular`) ので、距離マップ由来の候補も混ぜて
  「DB 未登録」バッジで区別する。
- **スタックの行に出す DCJ は「その図の基準との距離」にすること。** 基準を任意に
  選べるようになったので、距離マップの中心との距離を流用すると別の量を同じ列に
  出すことになる (#41 の「MST 経路長で代用しない」と同型)。
- 別クラスタ同士は実測で `dc-megablast` に落ちて共有 8.8% (どちらの経路を使ったかは
  出力に残る)、無関係なら `no_alignment`。**どちらも正常な応答**として扱う。

**プラスミドの carbapenemase は一度も記録されていなかった (2026-08-30 に判明)。**
`index.tsv` / `manifest.tsv` の `carbapenemase_genes` が全 8 アカウントで空だった。
原因は独立した 3 つで、**どれか 1 つでも残ると空のまま**になる:
1. **AMRFinder の出力キーの取り違え。** `parse_amrfinder.py` が書くのは `gene`
   なのに、抽出側は `gene_symbol` / `element` / `name` しか見ていなかった。
   これ単独で常に空になる。
2. **contig 名を素の文字列で比較していた。** MOB の contig_report と FASTA ヘッダは
   dnaapler が付けた `rotated=True rotated_gene=repA` まで持つが、**AMRFinder は
   最初の空白で切る**。実測 19396 で完全一致 0/2。
3. **公共アセンブリのヘッダは `contig_key` で吸収できない。** `CP136026.1
   Escherichia coli strain ... [topology=circular]` は `contig|tig|node|scaffold`
   の正規表現に当たらず、説明文ごと小文字化されて必ず外す。(2) を直しても
   harada_ndm は 0 件のままで、これを直して 14 件になった。
**修正**: 抽出を `circularity_util.carbapenemase_genes_from_amrfinder` に集約し
(`collect_plasmid_fastas.py` と `register_plasmids_to_db.py` は呼ぶだけ)、
突き合わせは `contig_match_key` (**先に最初のトークンだけにしてから** `contig_key`)。
既存 DB は `workflow/scripts/backfill_plasmid_carbapenemase.py` (dry-run 既定)。
**2026-08-30 に 114 行へ適用済み** (バックアップは各 DB の `_backup/<timestamp>/`)。
AMRFinder 結果が無い検体は触らない (不在を陰性にしない)。
**実データの規模**: 114 プラスミド / 5 アカウント
(toho_micro_id 66・toho_micro_id_bsi 23・harada_ndm 14・toho_micro_id_temp 9・kojima 2。
blaIMP-1 / blaIMP-6 / blaIMP-11 / blaNDM-5)。
**影響**: 表示だけでなく `merge_plasmid_clusters` の notable_clusters の
**並び順 (carba 保有を最優先)** と `num_carba_clusters` が効いていなかった
(常に 0)。クラスタが消えることは無いが、carbapenemase クラスタが上位に来ない。
**教訓**: 空欄は「非保有」と読めるので誰も気づかない (#28 と同型)。
**外部ツールの出力キーと contig 名の突き合わせは、実データで 1 件通してから
確定させること。**

**`carbapenemase_genes` は index.tsv に `;` 区切りで書かれている**
(`";".join(carba)`) のに読み出し側が `,` で割っていた。`_split_db_list` に
集約して両方受けるようにした。

**ダウンロードは `<a download>` を文書に挿入してからクリックし、revoke は
遅延させること。** 実測 2026-08-30: 切り離したままの `<a>` を click していたため
ブラウザが `download` 属性を無視し、**毎回同じ既定名で保存 = 2 つめが 1 つめを
上書き**していた。`URL.revokeObjectURL` を click 直後に同期で呼ぶのも同じ症状を
起こす (blob を読み終える前に消える)。ファイル名は**ミリ秒まで入れたうえで
同値なら連番を足す** — 秒までだと同じ比較を続けて保存したときに衝突して
1 つめが消える。「まず起きない」で済ませるとファイルが消える。
`pages/Results.tsx` の一括 HTML 出力も同じ壊れ方をしていたので
`downloadHtml` に寄せた (**blob をダウンロードさせる箇所は全部この形にすること**)。

**該当ファイル**: `workflow/scripts/compare_plasmid_structure.py` (新規・単一の真実源。
`compare` / `compare_stack` / `plasmid_fasta_candidates` — **パスの知識も API に
複製しないこと**), `workflow/tests/test_compare_plasmid_structure.py` (新規),
`api/services/result_parser.py` (`get_plasmid_structure_comparison` — uid を渡すだけ),
`api/routers/results.py` (`GET /api/results/plasmid_structure`。`query_uid` は配列で、
1 本ならペア・複数ならスタック),
`frontend/src/lib/api.ts` (`PlasmidStructureComparison` / `PlasmidStructureStack` 型),
`frontend/src/components/PlasmidStructureCompare.tsx` (新規・ペア),
`frontend/src/components/PlasmidStructureStack.tsx` (新規・スタック。直線/円環),
`frontend/src/lib/plasmidStructureExport.ts` (新規・DOM 複製による HTML 書き出し),
`frontend/src/lib/plasmidStructureColors.ts` (新規・色とリボン形状の共有定義),
`frontend/src/components/PlasmidComparePickerDialog.tsx` (新規・任意ペアの選択。
**基準との DCJ 列は距離マップのエッジではなく pling の全ペアから引く** — 距離マップは
中心と同じクラスタしか持たないので任意の基準には足りない),
`workflow/scripts/circularity_util.py` (`carbapenemase_genes_from_amrfinder`,
`contig_match_key`), `workflow/scripts/backfill_plasmid_carbapenemase.py` (新規),
`workflow/tests/test_carbapenemase_extraction.py` (新規),
`frontend/src/components/PlasmidDistanceMap.tsx` (`onCompare` — **effect の依存に
入れないこと**。力学配置が毎レンダーでリセットされる),
`frontend/src/components/PlasmidProfileSection.tsx` (**文脈キーを持たせて描画時に
判定する**。effect で setState して閉じると 1 フレーム古いペアの取得が飛ぶ)

**スクリプトは stdin で送ること。** base64 でコマンドラインに載せると単一引数が
約 71 KB になり Linux の `MAX_ARG_STRLEN` (128 KB) に余裕が無い
(`summary_row.py` は 17 KB なので既存経路はそのままでよい)。
**blastn の探索パスにユーザー名を決め打ちしないこと** — アカウント制のワーカーは
mbuser とは限らない。`_build_remote_command` の conda_init と同じ prefix 列を使う (#1)。

### 42.1 on-demand のプラスミドクラスタリングは強制再実行しないと空振りする
**症状 (実測 2026-08-31, toho_micro_id)**: 「プラスミド関連性 (クラスタ / DCJ MST /
Outbreak)」が全検体で消え、Results から「解析を実行」を押しても直らない。
ボタンは 202 を返し、実行ステータスも **completed になる**。

**原因は 2 段**:
1. **ジョブ完了後の自動フォローアップが、そのジョブの検体だけでクラスタリングして
   グループ全体の成果物を上書きする。** 4 検体のジョブの後、
   `plasmid_clusters_merged.json` が `num_plasmids: 9 / num_samples: 4` になり、
   **全 76 検体の `sample_plasmid_clusters.json` が `num_plasmids: 0` で上書き**
   された (#42 の「最後の実行で丸ごと上書きされる」がそのまま被害として出た形)。
2. **その状態から on-demand で回しても何も起きない。** `_build_plasmid_cluster_cmd`
   のターゲットは `plasmid_clusters/.done` で、workdir はジョブごとに新規 =
   snakemake のメタデータが無く**判定は mtime だけ**。前回の出力が残っているので
   「作るものが無い」となり **1 秒で終了**する。しかも最後に `.done` だけは更新
   されるため、`.done` の鮮度で完了を見る API 側は**成功と判定する** (#36 と同型)。
   痕跡の見分け方: `decision.json` の mtime が更新されていない = ルールが 1 つも
   走っていない。

**対処**: on-demand 経路 (`session is not None` = ボタン / API から明示実行) のみ
`--forcerun <クラスタリング系ルール>` を付ける。**`--forceall` にしないこと** —
`--allowed-rules` で終端入力として扱っている per-sample 成果物まで作り直そうとして
DAG が壊れる。自動フォローアップ (`session=None`) は従来どおり forcerun しない。

**未対処 (ユーザー決定 2026-08-31: 現状維持)**: 自動フォローアップを常にグループ
全体で回す案は採らなかった (毎ジョブの最後に 10〜20 分かかり、検体が増えるほど
延びるため)。したがって**新しい検体を投入するたびにグループ全体の関連性は
上書きされ、都度ボタンで復旧する運用**になる。

#### 続報: 「pling 完了直後に消える」の真因は**試行の重なり** (2026-08-31 確定)
強制再実行を入れて実行が 6 分級になった途端、**pling が exit=0 を書いた直後に
snakemake ごと消える**症状が 2 回再現した。ワーカーの snakemake ログは
`run_pling` のシェルを表示した行で終わり、**エラーも中断メッセージも残らない**。
- **カーネルは無関係**: `dmesg -T` に OOM も kill も無く、WSL VM は無停止
  (uptime 4 日)、RAM 216 GB。`mini_init drop_caches` は実行**後**の回収で結果側。
- **真因**: 1 ジョブの中で attempt 1〜3 が**重なって走っていた**。実測
  `plasmid_cluster_20260831_110512_877f70`: a1 11:05:16 起動 (11:10 まで生存) /
  a2 11:10:07 / a3 11:10:20。pling.log の `Batching 11:10:22` と a3 の
  snakemake ログ (11:10:22, 11:14:41) が 1 秒単位で一致し、**pling を回したのは
  a3**、a2 はその 13 秒前に同じ出力先へ入っていた。
- **壊し方**: `run_pling` は起動時に**共有の NAS 出力先を `rm -rf`** していた。
  後から入った実行が先行の pling 出力をディレクトリごと消すため、先行側は
  完了処理 (`pling/.done` と `.snakemake_timestamp` の作成) に到達できない。
  `pling/.done` が無いので次回も pling をやり直す、という悪循環になる。
- **なぜ重なったか**: 監視ストリームが先に切れて `exit=None` になり、PGID も
  取り逃がすと `_pgid_alive` が「死んだ」と判断して再投入する。**PGID だけを
  生存確認の根拠にしてはいけない。**
**対処 (実装済み)**:
1. 再投入の前に `pgrep -f 'snakemake.*{nas}/plasmid_clusters/.done'` で
   **出力先を掴んでいる snakemake を探す** (`_cluster_snakemake_running`)。
   居れば再投入せず待つ。**確認に失敗したときは「走っている」に倒す**
   (重ねるより待つほうが安全)。照合は必ずグループ固有のフルパスで行うこと —
   汎用語で撃つと無関係なジョブに当たる (#36.1)。
2. `run_pling` は**専用の一時ディレクトリで走らせ、成功したときだけ `mv` で
   差し替える**。共有の出力先をその場で消さない。後片付けは `$$` 付きの
   自分の一時ディレクトリだけを消す (**glob で消すと並走中の別実行を巻き込む**)。
3. 試行ごとに workdir を分ける (前掲) — ただしこれだけでは**NAS 出力先の共有**は
   解決しないので、1 と 2 が本体。
**該当ファイル**: `api/services/snakemake_runner.py`
(`_run_plasmid_cluster_batch`, `_build_plasmid_cluster_cmd(force=)`)

### 42.2 DB に置いた FASTA はヘッダが削れている — 環状情報を検体側から補う
**症状 (実測 2026-08-31)**: 26424__AA739 × 19397__AA739 の構造比較が
**全面的に交差した X 字**になり、「原点合わせ」を入れても直らない
(反転 381,493 bp / 共線性 0%)。同一クラスタの同じプラスミドなのに構造差が読めない。
**原因**: `estimate_frame` が枠を当てるのを諦めていた
(`frame.reason = "not_circular"`)。query 側 `db/plasmid_outbreak/by_cluster/
AA739/19397__AA739.fasta` のヘッダが **`>contig_2` だけ**で、環状かどうかも
`rotated_gene` も失われていたため。**実測で DB 159 本中 52 本 (33%)** が同じ状態
(古い版で登録されたもの)。`meta.json` の `circular` も `null`。
**ところが検体側には残っている** — `results/19397/mob_suite/mob_suite_result.json`
の contig レポートに `contig_2_length:369003_cov:114_circular rotated=True
rotated_gene=repA` がそのまま入っていた。
**直したこと**:
- `read_plasmid_index` の `circular` を **三値 (True / False / None=不明)** に。
  ヘッダに `_circular` も `_linear` も無いものを False に潰していたのが
  「直線だから原点を合わせない」という**誤った断定**になっていた (#28 と同型)。
- `fill_contig_flags()` で、不明のときだけ MOB-suite の記録から補う
  (**ヘッダにあるなら上書きしない**。出所は `circular_source` に残す)。
  特徴量 (AMR/rep/MGE) を読むのと同じ `results_dir` 経路なので新しい依存は無い。
- **回転と反転を分ける。** 回転 (原点ずらし) は環にしか意味が無いが、**反転は
  鎖の向きの取り替えなので直線でも定義できる**。環状と確認できない query でも
  反転だけは当て、`frame.reason="reverse_only_not_circular"` で何を当てたかを言う。
  UI も「原点を 0 bp ずらした」ではなく「向きだけ合わせた」と書き分ける。
**効果 (同一ペアの実測)**: 枠なし=共線性 0% → 反転のみ=**84%** →
反転+原点 45,223 bp=**92%**。図が対角線に乗り、残る 10,988 bp の反転区間
(本物の構造差) だけが逆向きに見える。
**キャッシュに注意**: `_structure_cache/` のキーは閾値と schema だけを見ており、
**判定ロジックを直しても古い図を返し続ける**。算出ロジック専用の
`LOGIC_VERSION` をキーに含めた。**判定を変えたら必ず上げること。**
**該当ファイル**: `workflow/scripts/compare_plasmid_structure.py`
(`read_plasmid_index` の三値化, `mob_contig_flags`, `fill_contig_flags`,
`estimate_frame`, `LOGIC_VERSION`), `workflow/tests/test_compare_plasmid_structure.py`,
`frontend/src/components/PlasmidStructureCompare.tsx` (枠の説明文),
`frontend/src/lib/api.ts` (`circular: boolean | null`)

### 43. 検体メタデータに地域 (国 / 都道府県) と施設を追加した
**動機**: 距離マップ (#41) は菌種と分離日しか軸を持たず、**「同じプラスミドが
どこまで広がったか」= 施設間・地域間の伝播が読めなかった**。院内 1 施設の群では
菌種軸も分離年軸も無地になる。分離日と同じ `sample_metadata` に相乗りさせる。

**表現方法 (自由テキスト 1 列にしない理由)**: 色分けと集計には**キー**が要る。
`東京` / `東京都` / `Tokyo` が別カテゴリになった時点で地域軸は意味を失う。
一方コードだけだと海外の未収載地域を表現できない。よって 3 列に分ける:
`country` (ISO 3166-1 alpha-2) + `region_code` (ISO 3166-2。**日本のみ**) +
`region_label` (表示ラベル。海外は自由入力のまま)。施設 (`facility`) は自由入力。
- **海外**: ISO 3166-2 の全世界テーブル (約 5,000 行) は同梱・保守しない。
  国は 249 件を全て持ち、**日本以外の第一次行政区画は自由入力**として
  `region_code=None` で保持する。GISAID / Nextstrain も Country / Division の
  自由記述で回っている。**alpha-3 (JPN) は受け付けない** — 変換表を別に抱えると
  誤りの温床になる。
- **正規化は `api/services/geography.py` だけが行う** (#19 の二重化事故の再発防止)。
  API は `region_key` / `region_display` / `facility_key` を**計算済みで**返し、
  frontend はそれで束ねて描くだけ。**フロントで正規化し直さないこと。**
- 集計キーは `region_code` → 無ければ `国:正規化ラベル` → それも無ければ `国`。
  **国だけ分かっている検体は国で束ねる** (分かっている情報を「未登録」に落とさない)。
  `_norm()` はアクセントを落とす (`Hyōgo`→`Hyogo`) が**かなの濁点は残す**
  (ハ ≠ バ)。

**踏んだ / 塞いだ点**:
- **既存 DB には列が入らない。** スキームは `CREATE TABLE IF NOT EXISTS` だけで
  移行機構が無かった。`PRAGMA table_info` を見て不足列だけ `ALTER TABLE ADD COLUMN`
  する `_migrate()` を追加 (冪等)。実データ 259 行 (kaoki_stec) は無傷。
- **`set_sample_isolation_date(None)` は行ごと DELETE していた。** 地域・施設が
  入った後にこれをやると巻き添えで消える。`upsert_sample_metadata(fields)` の
  部分更新に作り替え、**全項目が空になったときだけ**行を消す。`order_index`
  (同一分離日内の序列 = cgSNP の木の顔ぶれ) は必ず保つ。
- **CSV の空欄は「解除」ではなく「変更しない」。** 一括取り込みの空セルで既存の
  分離日や施設名が消えると被害が大きく、しかも気づきにくい。解除は UI から 1 件ずつ。
- **半分だけ取り込まない。** 日付や国名が解釈できない行は丸ごと飛ばす
  (どこまで入ったか後から分からなくなる)。**分離日の列は必須ではない**
  (地域・施設だけの表を受け付ける)。日付を持たない行は `order_index` を動かさない。
- **地域が空なら国も保存しない** (編集ダイアログ)。国だけ残すと地域軸に「日本」の
  1 カテゴリが立ち、分離日しか登録していない検体まで「地域 登録済み」に見える。
- **ワーカーへは配らない。** `db/isolation_dates.json` は cgSNP の並べ替え専用で、
  地域・施設は使わない。**NAS 上の共有 JSON に書き手を増やさない** (#25)。
  分離日を触ったときだけ再配布する。
- **未登録と取得失敗を書き分ける** (#28 / #40)。`epi_metadata_status` を返し、
  UI は「未登録」「取得失敗」を別の文言で出す。実データは地域・施設が 0 件なので、
  **無地に落ちない**ことを検証済み (既定軸は菌種のまま、表は「未登録」)。
- 色分けの既定軸は 菌種(≥2) → **地域(≥2)** → 分離年(≥2) → 出所。**施設は既定に
  しない** (院内 1 施設だと無地)。カテゴリ色は #41 と同じ **3 色 + その他 + 不明**
  の規則を `categoricalScheme()` 1 箇所に集約した (4 色目は CVD 検証を通らない)。
- **施設をまたぐエッジは菌種横断と同格**で出す (ツールチップ + サマリの警告)。
  「未登録 ↔ 何か」は**またぐと言わない** (不明は相違ではない)。
**プライバシー**: 施設名 + 分離日 + 菌種が揃うと症例が特定されうる。DB は
グループ scope で分離済みだが、**距離マップを HTML エクスポートに載せるなら
マスク切替を先に決めること** (現状エクスポートは距離マップを出力していない)。
**該当ファイル**: `api/services/geography.py` (新規・単一の真実源),
`api/services/sample_metadata.py` (`isolation_dates.py` から改名),
`api/services/account_store.py` (`_migrate`, `upsert_sample_metadata`),
`api/routers/results.py` (`_decorate_meta`, `GET /geography`,
`PUT /samples/{sample}/metadata`, 距離マップのノード付与),
`api/tests/test_geography.py` / `api/tests/test_sample_metadata_import.py` (新規),
`frontend/src/components/PlasmidDistanceMap.tsx` (`categoricalScheme`, 地域/施設軸),
`frontend/src/components/SampleMetadataDialog.tsx` (新規),
`frontend/src/components/SampleMetadataImportDialog.tsx` (`IsolationDateImportDialog`
から改名), `frontend/src/pages/Results.tsx`, `frontend/src/lib/api.ts`
