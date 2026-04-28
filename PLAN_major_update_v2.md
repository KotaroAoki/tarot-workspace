# TAROT-Analyzer メジャーアップデート計画
## マルチ入力アセンブリワークフロー (v2.0)

**作成日**: 2026-04-14  
**対象バージョン**: v1.x → v2.0

---

## 0. 現状サマリー (Phase 0 Discovery)

### 現在の制約
| 項目 | 現状 |
|------|------|
| 入力形式 | コンティグ FASTA のみ |
| アップロード | 個別ファイル選択 (FASTA 拡張子のみ) |
| サンプル検出 | FASTA ファイルを探索するだけ |
| アセンブリ | なし（済みのコンティグを渡す前提）|

### 参照スクリプト分析

**SPAdes ワークフロー** (`assembly_SPAdes_v3.15.1.sh`):
```
unpigz → cat R1/R2 → fastp (-w 24 -q 20 -t 1 -T 1 -l 50 -f 5 -F 5)
→ spades.py --isolate → seqkit seq -m 500 → seqkit stats
```

**Flye ワークフロー** (`Flye_v13_r10v14_q15_len5k_depth100.sh`):
```
unpigz → cat → NanoPlot(before) → fastplong (-M15 -f75 -l5000)
→ NanoPlot(after) → downsample(5Mbp×100x) → dechat(self-error correction)
→ seqkit rename → flye --nano-corr → Bandage → medaka_consensus
→ awk(ヘッダー書き換え) → seqkit sort -l -r → 塩基数修正 → dnaapler all
→ seqkit stats
```

### キーファイル一覧
```
workflow/Snakefile                          ← discover_samples() 要改修
workflow/rules/stage0_validation.smk        ← 入力 FASTA を検証
api/routers/upload.py                       ← ファイルアップロードエンドポイント
api/services/snakemake_runner.py            ← _discover_samples_remote() 要改修
api/models/schemas.py                       ← JobCreateRequest / Response
frontend/src/components/DropZone.tsx        ← ファイル単体 → ディレクトリに変更
frontend/src/pages/NewJob.tsx               ← ジョブ投入フォーム
config/config.yaml                          ← アセンブリ設定追加
```

---

## 1. 設計方針

### 1-1. 入力ディレクトリ構造

ユーザーは「**サンプルディレクトリ**」単位でアップロードする。  
各サンプルディレクトリ内のファイルを自動判定して解析モードを決定。

```
upload_root/
  sample_A/                      # Short read → SPAdes
    sample_A_R1_001.fastq.gz
    sample_A_R2_001.fastq.gz
  sample_B/                      # 既存コンティグ → アセンブリ不要
    sample_B_spades_contig.fasta
  sample_C/                      # Long read → Flye
    barcode01.fastq.gz           # または fastq_runid_*.fastq
```

### 1-2. 入力モード自動判定ロジック

| 優先度 | 条件 | モード |
|--------|------|--------|
| 1 | `.fasta`/`.fa`/`.fna` ファイルあり | `assembly_complete` |
| 2 | `*_R1*` + `*_R2*` の `.fastq.gz` ペアあり | `short_read` |
| 3 | ペアなし単一 `.fastq.gz`/`.fastq` あり | `long_read` |
| 4 | 両方あり (ハイブリッド) | `hybrid` (v2.1以降の将来対応、現在は short_read を優先) |

### 1-3. ファイル重複検知

アップロード前に「**ファイル名 + サイズ**」でリモートの既存ファイルと比較。  
一致するファイルはスキップ（転送なし）。

### 1-4. リードデータで実行可能な解析（アセンブリ不要）

| ツール | reads対応 | 実装方針 |
|--------|-----------|---------|
| SeqSero2 | ✅ `-m raw` (paired reads) | Salmonella short read で有効化 |
| Mash screen | ✅ (reads から sketch 可) | 任意、アセンブリ完了前の事前同定 |
| ResFinder | ✅ (CGE reads mode) | v2.x 以降の将来対応 |
| AMRFinder | ❌ contig 必須 | 変更なし |
| MLST | ❌ contig 推奨 | 変更なし |

---

## 2. 実装フェーズ

---

### Phase 1: 入力分類システム

**目標**: 各サンプルディレクトリを解析して入力モードを決定する  
Snakemake `checkpoint` で DAG を動的に構成する。

#### 1-A. `workflow/scripts/classify_input.py` (新規)

```python
# snakemake.input.sample_dir からディレクトリをスキャン
# snakemake.output[0] に JSON 出力
{
  "sample": "sample_A",
  "mode": "short_read",           # assembly_complete | short_read | long_read | hybrid
  "needs_assembly": true,
  "contig_path": null,            # assembly_complete 時のみ
  "short_reads": {
    "R1": "/path/to/R1.fastq.gz",
    "R2": "/path/to/R2.fastq.gz"
  },
  "long_reads": ["/path/to/barcode01.fastq.gz"],
  "all_files": [...]
}
```

**検出ルール**:
- コンティグ: 拡張子が `.fasta/.fa/.fna/.fsa/.fas` かつファイル名に `_R1/_R2` を含まない
- Short read: `*_R1*.fastq.gz` + `*_R2*.fastq.gz` のペア、または `*_1.fastq.gz` + `*_2.fastq.gz`
- Long read: `*.fastq.gz` または `*.fastq` の単一ファイル（R1/R2 なし）  
  Nanopore 特有パターン: `*barcode*`, `*RBK*`, `*fastq_runid_*`

#### 1-B. `workflow/rules/stage0_classify_input.smk` (新規)

```python
checkpoint classify_input:
    input:
        sample_dir = lambda wc: str(INPUT_DIR / wc.sample)
    output:
        RESULTS_DIR / "{sample}" / "input_class.json"
    script:
        "../scripts/classify_input.py"
```

#### 1-C. `workflow/Snakefile` 修正

```python
# 現在の discover_samples() を拡張:
# サブディレクトリ名をサンプル名として収集（FASTA だけでなく reads も含む）
def discover_samples(input_dir):
    samples = {}
    for subdir in sorted(input_path.iterdir()):
        if subdir.is_dir():
            # ファイルが1つ以上あればサンプルとして登録
            files = list(subdir.iterdir())
            if any(f.is_file() for f in files):
                samples[subdir.name] = str(subdir.resolve())
    # 後方互換: フラット FASTA も引き続きサポート
    ...
    return samples

# checkpoint の出力を使って入力 FASTA を解決
def get_input_fasta(wildcards):
    import json
    cls = checkpoints.classify_input.get(**wildcards).output[0]
    info = json.load(open(cls))
    if info["mode"] == "assembly_complete":
        return info["contig_path"]
    else:
        return str(RESULTS_DIR / wildcards.sample / "assembly" / "contigs.fasta")
```

#### 検証チェックリスト
- [ ] `classify_input.py` を単体実行して各ディレクトリ構造で正しい JSON が出力される
- [ ] Snakemake `--dry-run` でコンティグサンプルが assembly ルールをスキップする
- [ ] Short read サンプルで `short_read` モードが検出される

---

### Phase 2: アセンブリルール

#### 2-A. SPAdes (Short Read) — `workflow/rules/stage1_spades_assembly.smk` (新規)

**依存**: `stage0_classify_input.smk` の checkpoint output  
**入力**: `input_class.json` の `short_reads.R1` / `short_reads.R2`  
**出力**: `results/{sample}/assembly/contigs.fasta`

```
step 1: fastp PE
  -w {threads} -i {R1} -I {R2}
  -o trimmed_R1.fq -O trimmed_R2.fq
  -3 -q {config[assembly][short_read][fastp_quality]}
  -t 1 -T 1
  -l {config[assembly][short_read][fastp_min_len]}
  -f {config[assembly][short_read][fastp_trim_front]}
  -F {config[assembly][short_read][fastp_trim_front]}
  → seqkit stats -a > trimmed_reads_stats.txt

step 2: spades.py --isolate
  -1 trimmed_R1.fq -2 trimmed_R2.fq
  -t {threads} -o spades_output/

step 3: seqkit seq -m {min_contig_length}
  spades_output/contigs.fasta → contigs.fasta

step 4: seqkit stats -a > assembly_stats.txt

step 5: rm 中間ファイル、元 fastq を pigz 再圧縮
```

**config.yaml 追加**:
```yaml
assembly:
  short_read:
    fastp_quality: 20
    fastp_min_len: 50
    fastp_trim_front: 5
    min_contig_length: 500
```

#### 2-B. Flye (Long Read) — `workflow/rules/stage1_flye_assembly.smk` (新規)

**入力**: `input_class.json` の `long_reads` リスト  
**出力**: `results/{sample}/assembly/contigs.fasta`

```
step 1: unpigz + cat (Nanopore multi-file → cat_reads.fastq)
  パターン: {fastq_runid_*, *barcode*, *RBK114*}.fastq (または全 .fastq.gz)

step 2: NanoPlot --fastq cat_reads.fastq --loglength (QC before)

step 3: fastplong
  -M {min_quality} -f 75 -l {min_len} -i cat_reads.fastq
  -o cat_reads_trimmed.fastq -w {threads}

step 4: NanoPlot (QC after)

step 5: ダウンサンプリング
  total_bases = NanoStats.txt から取得
  sampling_rate = (genome_size × coverage) / total_bases
  seqkit sample -p {sampling_rate} → downsampled.fastq

step 6: dechat (self-error correction)
  -i downsampled.fastq -o dechat_output -t {threads}

step 7: seqkit rename -n → unique_reads.fa

step 8: flye --nano-corr
  unique_reads.fa --out-dir flye_output
  --threads {threads} -m {min_overlap} --keep-haplotypes

step 9: Bandage image (アセンブリグラフ可視化)

step 10: medaka_consensus
  -i unique_reads.fa -d flye_output/assembly.fasta
  -o medaka_output -t {threads}
  -m {config[assembly][long_read][medaka_model]}

step 11: awk ヘッダー書き換え (assembly_info.txt から length/cov/circular)

step 12: seqkit sort -l -r -w 0 (長い順ソート)

step 13: 塩基数修正スクリプト (ヘッダーの length を実際の塩基数に修正)

step 14: dnaapler all

step 15: seqkit stats → contigs.fasta として出力
  rm 中間ファイル、pigz 再圧縮
```

**config.yaml 追加**:
```yaml
  long_read:
    fastplong_min_quality: 15
    fastplong_min_len: 5000
    target_depth: 100
    genome_size: 5000000
    flye_min_overlap: 5000
    medaka_model: r941_min_high_g303
```

#### 2-C. Snakefile — rule all の拡張

```python
rule all:
    input:
        # 分類 JSON (常に生成)
        expand(RESULTS_DIR / "{sample}" / "input_class.json", sample=SAMPLES),
        # アセンブリ (needs_assembly=true のサンプルのみ checkpoint で決定)
        # 最終レポート
        expand(RESULTS_DIR / "{sample}" / "report" / "{sample}_report.json", sample=SAMPLES),
```

#### 検証チェックリスト
- [ ] Short read サンプルで SPAdes が走り `assembly/contigs.fasta` が生成される
- [ ] Long read サンプルで Flye → medaka → dnaapler が完走する
- [ ] 既存コンティグサンプルで assembly ルールがスキップされる
- [ ] 全パスで最終 `_report.json` が正常に生成される

---

### Phase 3: リードデータ直接解析（SeqSero2）

**目標**: Salmonella 判定済み short read サンプルで `-m raw` を有効化  
（アセンブリ完了を待たず血清型判定が可能になる）

#### `workflow/rules/stage1_seqsero2.smk` 修正

現在: コンティグ FASTA を `-m 3` (FASTA モード) で渡す

変更後:
```python
def _get_seqsero2_input(wildcards):
    cls = checkpoints.classify_input.get(**wildcards).output[0]
    info = json.load(open(cls))
    if info["mode"] == "short_read":
        return {"R1": info["short_reads"]["R1"], "R2": info["short_reads"]["R2"]}
    else:
        return {"contigs": get_input_fasta(wildcards)}

# shell 内:
# short_read → seqsero2 -t 2 -m raw -i {input.R1} {input.R2}
# その他 → 現行の -t 4 (FASTA) モード
```

**注意**: Salmonella 判定前（species_id 完了前）に実行できるため、  
並列処理の観点で assembly と同時進行可能。ただし Salmonella でない場合は  
依然として SKIPPED マーカーを出力する（現行ロジック維持）。

#### 検証チェックリスト
- [ ] Salmonella short read サンプルで SeqSero2 が `-m raw` で実行される
- [ ] 非 Salmonella では SKIPPED が出力される
- [ ] 既存コンティグサンプルでは現行動作が変わらない

---

### Phase 4: アップロード API (ディレクトリ対応 + 重複検知)

#### 4-A. `api/routers/upload.py` — 新エンドポイント追加

`POST /api/upload/directory` (既存の `POST /api/upload` は互換維持)

**Request**: `multipart/form-data`  
ブラウザは `webkitRelativePath` で相対パス付きでファイルを送る。

```
files: [
  {filename: "sample_A/R1.fastq.gz", content: ...},
  {filename: "sample_A/R2.fastq.gz", content: ...},
  {filename: "sample_B/contigs.fasta", content: ...},
]
```

**処理フロー**:
```
1. ファイルを {sample}/{filename} の相対パスで受信
2. manifest 生成: {relative_path, size}
3. リモートの既存ファイルと比較 (sftp_listdir_recursive)
4. 差分ファイルのみ SFTP 転送
5. クライアント側の分類ロジックで sample モードを判定して返却
```

**Response**:
```json
{
  "session_id": "20260414_120000_abc123",
  "input_dir": "/home/mbuser/.../uploads/20260414_120000_abc123",
  "samples": [
    {"name": "sample_A", "mode": "short_read",  "files": ["R1.fastq.gz", "R2.fastq.gz"]},
    {"name": "sample_B", "mode": "assembly_complete", "files": ["contigs.fasta"]}
  ],
  "skipped": ["sample_B/contigs.fasta"],
  "errors": [],
  "total_uploaded": 2,
  "total_skipped": 1
}
```

#### 4-B. `api/services/ssh_manager.py` — 新メソッド追加

```python
async def sftp_listdir_recursive(
    self, token: str, remote_dir: str
) -> dict[str, int]:
    """remote_dir 以下のファイルを再帰的にリスト (relative_path → size)"""
```

重複判定: `relative_path` と `size` が一致すればスキップ

#### 4-C. `api/models/schemas.py` — 新スキーマ追加

```python
class InputMode(str, Enum):
    ASSEMBLY_COMPLETE = "assembly_complete"
    SHORT_READ = "short_read"
    LONG_READ = "long_read"
    HYBRID = "hybrid"

class SampleInputInfo(BaseModel):
    name: str
    mode: InputMode
    files: list[str]

class DirectoryUploadResponse(BaseModel):
    session_id: str
    input_dir: str
    samples: list[SampleInputInfo]
    skipped: list[str]
    errors: list[str]
    total_uploaded: int
    total_skipped: int
```

#### 検証チェックリスト
- [ ] ディレクトリ構造が正しくリモートに再現される
- [ ] 同一ファイル (同名+同サイズ) が重複アップロードされない
- [ ] `samples` レスポンスに正しいモードが返る

---

### Phase 5: フロントエンド (ディレクトリ対応)

#### 5-A. `frontend/src/components/DropZone.tsx` 改修

**変更点**:
1. `<input type="file">` に `webkitdirectory` 属性を追加
2. Drag & Drop で `e.dataTransfer.items` + `webkitGetAsEntry()` を使用してディレクトリを再帰取得
3. `allowedExtensions` をリード + コンティグ両方に拡張:
   ```ts
   const ALLOWED_EXTENSIONS = [
     '.fasta', '.fa', '.fna', '.fsa', '.fas',   // contigs
     '.fastq.gz', '.fastq',                      // reads
   ]
   ```
4. API 呼び出しを `/api/upload/directory` に変更、`webkitRelativePath` を相対パスとして送信
5. アップロード完了後、サンプル別モードバッジ表示:
   ```
   sample_A  [Short Read ▶ SPAdes]  R1.fastq.gz, R2.fastq.gz
   sample_B  [Assembled]            contigs.fasta
   sample_C  [Long Read ▶ Flye]    barcode01.fastq.gz
   ```

#### 5-B. `frontend/src/pages/NewJob.tsx` 改修

- `onUploaded` コールバックに `SampleInputInfo[]` を渡してプレビューテーブルを表示
- モード別チップ: 緑 = Assembled / 青 = Short Read / オレンジ = Long Read

#### 5-C. `frontend/src/lib/api.ts` — 新関数追加

```ts
export async function uploadDirectory(files: File[]): Promise<DirectoryUploadResponse> {
  const fd = new FormData()
  for (const f of files) {
    fd.append('files', f, f.webkitRelativePath || f.name)
  }
  return apiFetch('/api/upload/directory', { method: 'POST', body: fd })
}
```

#### 検証チェックリスト
- [ ] ディレクトリをドラッグ & ドロップで全ファイルが収集される
- [ ] `webkitdirectory` でフォルダ選択できる
- [ ] サンプルカードにモードバッジが表示される
- [ ] 既存コンティグが緑 "Assembled" と表示される

---

### Phase 6: snakemake_runner.py 改修

#### 6-A. `_discover_samples_remote()` — サブディレクトリをサンプル名として検出

```python
# 現在: FASTA ファイルを検索
# 変更後: サブディレクトリ名 (= サンプル名) を検索
stdout, _, _ = await ssh.exec_command(
    token,
    f'find "{input_dir}" -maxdepth 1 -mindepth 1 -type d | sort'
)
samples = [Path(p).name for p in stdout.strip().split("\n") if p.strip()]
```

後方互換: サブディレクトリがない場合はフラット FASTA も検索。

#### 6-B. `JobRecord` に `sample_modes` 追加

```python
self.sample_modes: dict[str, str] = {}  # {sample: "short_read"|"assembly_complete"|...}
```

`_run_all_batches` 完了後に `input_class.json` を SFTP で読んで設定。  
フロントエンドの JobDetail でモードを表示可能にする。

---

## 3. 実装順序と依存関係

```
Phase 1 (入力分類) 
  → Phase 2 (アセンブリルール)  ← classify_input.py の出力を参照
  → Phase 3 (SeqSero2 reads)   ← classify_input.py の出力を参照
  → Phase 4 (アップロード API) ← 独立して実施可能
  → Phase 5 (フロントエンド)   ← Phase 4 の新 API に依存
  → Phase 6 (runner 改修)      ← Phase 1 のリモートディレクトリ構造に依存
```

## 4. 未実装・将来対応

| 項目 | 優先度 | 備考 |
|------|--------|------|
| Hybrid assembly (Unicycler) | 低 | Short + Long 同時入力 |
| ResFinder from reads | 中 | CGE reads モード対応 |
| AMRFinder from reads | 低 | reads 対応は限定的 |
| Mash from reads (事前同定) | 中 | アセンブリ前の速報 |
| MD5 ベースの重複検知 | 中 | 現状はファイル名+サイズ |

## 5. 変更ファイル一覧

| ファイル | 変更種別 |
|----------|---------|
| `workflow/scripts/classify_input.py` | **新規** |
| `workflow/rules/stage0_classify_input.smk` | **新規** |
| `workflow/rules/stage1_spades_assembly.smk` | **新規** |
| `workflow/rules/stage1_flye_assembly.smk` | **新規** |
| `workflow/Snakefile` | 修正 |
| `workflow/rules/stage1_seqsero2.smk` | 修正 |
| `config/config.yaml` | 修正 (assembly セクション追加) |
| `api/routers/upload.py` | 修正 (ディレクトリエンドポイント追加) |
| `api/services/ssh_manager.py` | 修正 (`sftp_listdir_recursive` 追加) |
| `api/services/snakemake_runner.py` | 修正 |
| `api/models/schemas.py` | 修正 (InputMode / SampleInputInfo 追加) |
| `frontend/src/components/DropZone.tsx` | 修正 |
| `frontend/src/pages/NewJob.tsx` | 修正 |
| `frontend/src/lib/api.ts` | 修正 |
