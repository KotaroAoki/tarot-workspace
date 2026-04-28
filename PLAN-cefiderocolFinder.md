# CefiderocolFinder 統合実装プラン

## Phase 0: 調査結果サマリー（Documentation Discovery）

### CefiderocolFinder の仕様 (GitHub調査済み)

| 項目 | 内容 |
|------|------|
| リポジトリ | https://github.com/Bryan-vd-Brand/CefiderocolFinder |
| 入力形式 | **paired-end FASTQ のみ** (FASTAコンティグ不可) |
| 対応菌種 | Acinetobacter baumannii / Escherichia coli / Klebsiella pneumoniae / Pseudomonas aeruginosa |
| 実行コマンド | `python main.py --reads R1 R2 --output DIR --species SPECIES --name NAME --config CONFIG --threads N` |
| 主な出力 | `{name}_frameshiftVariants.tsv`, `{name}_otherVariants.tsv`, `{name}_finish.touch` |
| 出力列 | Name, Gene, CHROM, POS, ID, REF, ALT, QUAL, FILTER, AC, AF, AN, DP, ANN, LOF, NMD など27列 |
| conda env | `CefiderocolFinder_conda.yaml` (Python 3.10, bwa, samtools, snpEff, GATK, PyTorch, PyMC — 200+パッケージ) |
| 特記 | GATK 4.6.1.0 は別途手動ダウンロードが必要 (Broadinstitute) |

### 既存パイプラインとの統合ポイント

| 層 | 参照パターン | 変更ファイル |
|---|---|---|
| Snakemake | `stage1_amrfinder.smk` (conda切替 #14, SKIPPEDパターン) | 新規 `stage1_cefiderocolFinder.smk` |
| Parser | `parse_amrfinder.py` | 新規 `parse_cefiderocolFinder.py` |
| 入力モード | `classify_input.py` → `input_class.json` の `mode`/`short_reads` | 読み取り専用 |
| Report集約 | `per_sample_report.py` の `_build_XXX_section()` パターン | 既存ファイル修正 |
| API | `result_parser.py` の `MODULE_FILE_MAP` / `MODULE_CHECK_MAP` | 既存ファイル修正 |
| Frontend | `JobDetail.tsx` の `MODULE_LABELS` + `extractModuleRows` case | 既存ファイル修正 |
| Config | `config.yaml` の `amrfinder` セクション相当 | 既存ファイル修正 |

### 入力モード別 reads 調達戦略

| mode | 調達方法 |
|------|---------|
| `short_read` | `input_class.json` の `short_reads.R1/R2` を直接使用 |
| `hybrid` | `input_class.json` の `short_reads.R1/R2` を直接使用 |
| `long_read` | `assembly/long_read/contigs.fasta`（medaka polish + dnaapler 済み）→ **wgsim** で擬似 paired-end 生成 |
| `assembly_complete` | `input/contigs.fasta` → **wgsim** で擬似 paired-end 生成 |
| その他 | SKIPPED |

### 実行条件（スキップゲート）
- 上記以外のモード → SKIPPED
- `species_id_merged.json` の判定種が `species_map` にない → SKIPPED

---

## Phase 1: リモートサーバーセットアップ（手動作業）

> **実施者**: ユーザーが WSL2 サーバー (172.20.17.98:2222, mbuser) にて実施

### 1-1. CefiderocolFinder リポジトリのクローン

```bash
cd /home/mbuser
git clone https://github.com/Bryan-vd-Brand/CefiderocolFinder
cd CefiderocolFinder
```

### 1-2. GATK 4.6.1.0 のダウンロードと配置

```bash
# Broadinstitute から gatk-4.6.1.0.zip を取得し展開
# 以下3ファイルを /home/mbuser/CefiderocolFinder/ に配置:
#   gatk-package-4.6.1.0-local.jar
#   gatkPythonPackageArchive.zip
#   gatk  (ラッパースクリプト)
```

### 1-3. conda 環境の構築

```bash
cd /home/mbuser/CefiderocolFinder
conda env create -f CefiderocolFinder_conda.yaml
# 環境名: CefiderocolFinder_env (yamlのname:フィールドを確認)
conda activate CefiderocolFinder_env
```

### 1-4. 参照ゲノムのダウンロード（snpEff DB 含む）

config_cefiderocolFinder.yml に各菌種の参照ゲノムパスを設定:

```yaml
# /home/mbuser/CefiderocolFinder/config_cefiderocolFinder.yml
Acinetobacter_baumannii: "/home/mbuser/dbs/cefiderocolFinder/refs/NZ_CP045110.fasta"
Escherichia_coli:        "/home/mbuser/dbs/cefiderocolFinder/refs/NC_000913.fasta"
Klebsiella_pneumoniae:   "/home/mbuser/dbs/cefiderocolFinder/refs/NZ_CP117227.fasta"
Pseudomonas_aeruginosa:  "/home/mbuser/dbs/cefiderocolFinder/refs/NC_002516.fasta"
Acinetobacter_baumannii_accession: "NZ_CP045110"
Escherichia_coli_accession:        "NC_000913"
Klebsiella_pneumoniae_accession:   "NZ_CP117227"
Pseudomonas_aeruginosa_accession:  "NC_002516"
```

### 1-5. wgsim のインストール

wgsim は bioconda パッケージ。py39 環境に追加インストールする:

```bash
conda activate py39
conda install -c bioconda wgsim
wgsim 2>&1 | head -5   # ヘルプが出ればOK
```

> wgsim は CefiderocolFinder conda env に含まれないため、py39 で実行し、
> その出力 FASTQ を CefiderocolFinder env に渡す設計にする。

### 1-6. 検証チェックリスト

- [ ] `conda activate CefiderocolFinder_env && python /home/mbuser/CefiderocolFinder/main.py --help` が正常終了
- [ ] `ls /home/mbuser/dbs/cefiderocolFinder/refs/*.fasta` で4ファイル存在確認
- [ ] `/home/mbuser/CefiderocolFinder/gatk --version` が正常実行
- [ ] `conda activate py39 && wgsim 2>&1 | grep -q "Usage"` が正常終了

---

## Phase 2: config.yaml 更新

**ファイル**: `tarot-analyzer/config/config.yaml`

### 追加するセクション

```yaml
cefiderocolFinder:
  enabled: true
  conda_env: "CefiderocolFinder_env"          # conda env name (Phase 1-3 で確認)
  tool_dir: "/home/mbuser/CefiderocolFinder"  # リモートの main.py が存在するディレクトリ
  config_path: "/home/mbuser/CefiderocolFinder/config_cefiderocolFinder.yml"
  threads: 8
  min_dp: 10                # --minDP (最小リードデプス)
  # wgsim パラメータ (long_read / assembly_complete モード用)
  wgsim:
    read_length: 150        # -1 / -2: リード長 (bp), Illumina 標準
    insert_size: 400        # -d: outer insert size (bp)
    insert_sd: 50           # -s: insert size 標準偏差 (bp)
    coverage: 50            # ゲノムサイズから算出するターゲットカバレッジ
    error_rate: 0.0         # -e: 塩基エラーレート (0 = perfect reads)
    mutation_rate: 0.0      # -r: SNP 導入率 (0 = no artificial mutations)
    seed: 42                # -S: 乱数シード (再現性確保)
  # 対応菌種マップ: species_id_merged.json の species_id → --species 引数
  species_map:
    "acinetobacter baumannii": "Acinetobacter_baumannii"
    "acinetobacter":           "Acinetobacter_baumannii"
    "escherichia coli":        "Escherichia_coli"
    "escherichia":             "Escherichia_coli"
    "klebsiella pneumoniae":   "Klebsiella_pneumoniae"
    "klebsiella":              "Klebsiella_pneumoniae"
    "pseudomonas aeruginosa":  "Pseudomonas_aeruginosa"
    "pseudomonas":             "Pseudomonas_aeruginosa"
```

### 検証

```bash
python -c "import yaml; c=yaml.safe_load(open('tarot-analyzer/config/config.yaml')); print(c['cefiderocolFinder'])"
```

---

## Phase 3: Snakemake ルール作成

**新規ファイル**: `tarot-analyzer/workflow/rules/stage1_cefiderocolFinder.smk`

### 設計方針

- **参照**: `stage1_amrfinder.smk` の conda 切替パターン (CLAUDE.md #14)
- 入力: `input_class.json` (モード・R1/R2 パス) + `species_id_merged.json` (菌種判定)
- **モード別 reads 調達**:
  - `short_read` / `hybrid` → `input_class.json` から R1/R2 を直接取得
  - `long_read` → `contigs.fasta` (Flye/DeChat pipeline出力) を wgsim で擬似 FASTQ 化
  - `assembly_complete` → `input/contigs.fasta` を wgsim で擬似 FASTQ 化
  - その他 → SKIPPED
- wgsim は **py39 環境**で実行 (CefiderocolFinder env に含まれないため)
- SKIPPED時: 空TSV + touch を生成して正常終了

```python
import json as _json

# ── ヘルパー: condaシェル関数の初期化スニペット ──
_CONDA_INIT = (
    "for p in ~/mambaforge ~/miniforge3 ~/miniconda3 ~/anaconda3 /opt/conda; do "
    'if [ -f "$p/etc/profile.d/conda.sh" ]; then . "$p/etc/profile.d/conda.sh"; break; fi; '
    "done"
)

def _resolve_cefi_species(species_id_path):
    """species_id_merged.json → CefiderocolFinder --species 引数を解決"""
    try:
        with open(species_id_path) as f:
            data = _json.load(f)
        sid = (data.get("species_id") or "").lower().strip()
        return config.get("cefiderocolFinder", {}).get("species_map", {}).get(sid, "")
    except Exception:
        return ""

def _get_contigs_for_cefi(wildcards):
    """
    long_read / assembly_complete モードのみ contigs.fasta パスを返す。
    short_read / hybrid は空リスト (wgsim 不要)。
    checkpoint classify_input に依存。
    """
    cls = checkpoints.classify_input.get(**wildcards).output[0]
    info = _json.load(open(cls))
    mode = info.get("mode", "unknown")
    if mode == "long_read":
        # flye_assembly rule の output.contigs = medaka polish + dnaapler 済みの最終 FASTA
        return [str(RESULTS_DIR / wildcards.sample / "assembly" / "long_read" / "contigs.fasta")]
    elif mode == "assembly_complete":
        return [str(RESULTS_DIR / wildcards.sample / "input" / "contigs.fasta")]
    return []  # short_read / hybrid: wgsim不要

# ── rule: run CefiderocolFinder ──────────────────
rule cefiderocolFinder:
    input:
        input_class = RESULTS_DIR / "{sample}" / "input_class.json",
        species_id  = RESULTS_DIR / "{sample}" / "species_id" / "species_id_merged.json",
        contigs     = lambda wc: _get_contigs_for_cefi(wc),  # mode依存 (空リストOK)
    output:
        frameshift = RESULTS_DIR / "{sample}" / "cefiderocolFinder" / "{sample}_frameshiftVariants.tsv",
        other      = RESULTS_DIR / "{sample}" / "cefiderocolFinder" / "{sample}_otherVariants.tsv",
        touch      = RESULTS_DIR / "{sample}" / "cefiderocolFinder" / "{sample}_finish.touch",
    log:
        LOG_DIR / "{sample}" / "cefiderocolFinder.log",
    params:
        tool_dir     = config.get("cefiderocolFinder", {}).get("tool_dir", ""),
        config_path  = config.get("cefiderocolFinder", {}).get("config_path", ""),
        conda_env    = config.get("cefiderocolFinder", {}).get("conda_env", "CefiderocolFinder_env"),
        threads      = config.get("cefiderocolFinder", {}).get("threads", 8),
        min_dp       = config.get("cefiderocolFinder", {}).get("min_dp", 10),
        cefi_species = lambda w, input: _resolve_cefi_species(input.species_id),
        out_dir      = lambda w: str(RESULTS_DIR / w.sample / "cefiderocolFinder"),
        # wgsim パラメータ
        wgsim_rlen   = config.get("cefiderocolFinder", {}).get("wgsim", {}).get("read_length", 150),
        wgsim_isize  = config.get("cefiderocolFinder", {}).get("wgsim", {}).get("insert_size", 400),
        wgsim_isd    = config.get("cefiderocolFinder", {}).get("wgsim", {}).get("insert_sd", 50),
        wgsim_cov    = config.get("cefiderocolFinder", {}).get("wgsim", {}).get("coverage", 50),
        wgsim_err    = config.get("cefiderocolFinder", {}).get("wgsim", {}).get("error_rate", 0.0),
        wgsim_mut    = config.get("cefiderocolFinder", {}).get("wgsim", {}).get("mutation_rate", 0.0),
        wgsim_seed   = config.get("cefiderocolFinder", {}).get("wgsim", {}).get("seed", 42),
    shell:
        """
        set +e
        (
            set -euo pipefail

            # ── conda 再初期化 (Snakemakeルールはbashを新規起動: CLAUDE.md #14) ──
            {_CONDA_INIT}

            mkdir -p {params.out_dir}
            SKIP_TSV_HEADER="Name\tGene\tCHROM\tPOS\tREF\tALT"

            # ── 菌種チェック (最初に実行してコスト節約) ──
            CEFI_SPECIES="{params.cefi_species}"
            if [ -z "$CEFI_SPECIES" ]; then
                echo "SKIP: species not supported by CefiderocolFinder" | tee -a {log}
                printf "$SKIP_TSV_HEADER\n" > {output.frameshift}
                printf "$SKIP_TSV_HEADER\n" > {output.other}
                touch {output.touch}
                exit 0
            fi

            # ── 入力モード判定 & R1/R2 調達 ──
            MODE=$(python3 -c "import json; d=json.load(open('{input.input_class}')); print(d.get('mode','unknown'))")
            echo "[cefi] mode=$MODE species=$CEFI_SPECIES" | tee -a {log}

            if [[ "$MODE" == "short_read" || "$MODE" == "hybrid" ]]; then
                # ── 実リード: input_class.json から R1/R2 取得 ──
                R1=$(python3 -c "import json; d=json.load(open('{input.input_class}')); print(d['short_reads']['R1'])")
                R2=$(python3 -c "import json; d=json.load(open('{input.input_class}')); print(d['short_reads']['R2'])")
                echo "[cefi] Using real reads: $R1 / $R2" | tee -a {log}

                    elif [[ "$MODE" == "long_read" || "$MODE" == "assembly_complete" ]]; then
                # ── wgsim で擬似 paired-end 生成 ──
                # long_read: fastplong → DeChat → Flye → medaka polish → dnaapler の最終 contigs.fasta を使用
                CONTIGS="{input.contigs}"
                echo "[cefi] Simulating reads from $CONTIGS with wgsim" | tee -a {log}

                # ゲノムサイズを seqkit stats から取得してリード数を計算
                GENOME_SIZE=$(seqkit stats -T "$CONTIGS" 2>>{log} | awk 'NR==2{{print $5}}')
                if [ -z "$GENOME_SIZE" ] || [ "$GENOME_SIZE" -eq 0 ] 2>/dev/null; then
                    GENOME_SIZE=5000000  # fallback: 5 Mbp
                    echo "[cefi] WARNING: Could not get genome size, using fallback 5Mbp" | tee -a {log}
                fi
                NUM_PAIRS=$(python3 -c "print(max(1000, int($GENOME_SIZE * {params.wgsim_cov} / {params.wgsim_rlen} / 2)))")
                echo "[cefi] genome_size=$GENOME_SIZE  num_pairs=$NUM_PAIRS" | tee -a {log}

                WGSIM_R1="{params.out_dir}/wgsim_R1.fastq"
                WGSIM_R2="{params.out_dir}/wgsim_R2.fastq"

                # wgsim は py39 env で実行 (CefiderocolFinder env に含まれない)
                conda deactivate 2>/dev/null || true
                conda activate py39

                wgsim \
                    -N $NUM_PAIRS \
                    -1 {params.wgsim_rlen} \
                    -2 {params.wgsim_rlen} \
                    -d {params.wgsim_isize} \
                    -s {params.wgsim_isd} \
                    -e {params.wgsim_err} \
                    -r {params.wgsim_mut} \
                    -R 0 \
                    -S {params.wgsim_seed} \
                    "$CONTIGS" \
                    "$WGSIM_R1" \
                    "$WGSIM_R2" \
                    2>&1 | tee -a {log}

                conda deactivate 2>/dev/null || true
                R1="$WGSIM_R1"
                R2="$WGSIM_R2"
                echo "[cefi] wgsim done: $R1 ($( wc -l < $R1 ) lines)" | tee -a {log}

            else
                echo "SKIP: unsupported mode $MODE" | tee -a {log}
                printf "$SKIP_TSV_HEADER\n" > {output.frameshift}
                printf "$SKIP_TSV_HEADER\n" > {output.other}
                touch {output.touch}
                exit 0
            fi

            # ── CefiderocolFinder 実行 ──
            conda deactivate 2>/dev/null || true
            conda activate {params.conda_env}

            python {params.tool_dir}/main.py \
                --reads "$R1" "$R2" \
                --output {params.out_dir} \
                --species "$CEFI_SPECIES" \
                --name {wildcards.sample} \
                --config {params.config_path} \
                --threads {params.threads} \
                --minDP {params.min_dp} \
                --fastqc False \
                2>&1 | tee -a {log}

            # ── wgsim 一時ファイル削除 ──
            rm -f "{params.out_dir}/wgsim_R1.fastq" "{params.out_dir}/wgsim_R2.fastq"

        ) 2>&1 | tee -a {log}
        EXIT=${{PIPESTATUS[0]}}
        set -e
        exit $EXIT
        """

# ── rule: parse CefiderocolFinder output ─────────
rule parse_cefiderocolFinder:
    input:
        frameshift  = RESULTS_DIR / "{sample}" / "cefiderocolFinder" / "{sample}_frameshiftVariants.tsv",
        other       = RESULTS_DIR / "{sample}" / "cefiderocolFinder" / "{sample}_otherVariants.tsv",
        touch       = RESULTS_DIR / "{sample}" / "cefiderocolFinder" / "{sample}_finish.touch",
        species_id  = RESULTS_DIR / "{sample}" / "species_id" / "species_id_merged.json",
        input_class = RESULTS_DIR / "{sample}" / "input_class.json",
    output:
        json_report = RESULTS_DIR / "{sample}" / "cefiderocolFinder" / "cefiderocolFinder_result.json",
    script:
        "../scripts/parse_cefiderocolFinder.py"
```

### Snakefile への組み込み

`workflow/Snakefile` に以下を追加:

```python
# include リストに追加 (他のstage1ルールと並べる)
include: "rules/stage1_cefiderocolFinder.smk"
```

> `rule all` のターゲットは `{sample}_report.json` 経由で自動的に要求されるため変更不要

### 検証チェックリスト

- [ ] `snakemake --dryrun` でルール解決エラーがないことを確認
- [ ] `short_read` + 対応菌種のドライランが通ること (wgsim なし)
- [ ] `long_read` + 対応菌種のドライランが通ること (`contigs.fasta` への依存が解決される)
- [ ] `assembly_complete` サンプルのドライランが通ること
- [ ] `contigs-only` など非対応モードで SKIPPED パスが通ること

---

## Phase 4: 結果パーサー作成

**新規ファイル**: `tarot-analyzer/workflow/scripts/parse_cefiderocolFinder.py`

### 出力 JSON 構造

```json
{
  "module": "cefiderocolFinder",
  "status": "PASS" | "FAIL" | "SKIPPED",
  "species": "Klebsiella_pneumoniae",
  "frameshift_variants": [
    {
      "gene": "string",
      "chrom": "string",
      "pos": "number",
      "ref": "string",
      "alt": "string",
      "dp": "number",
      "annotation": "string",
      "lof": "string"
    }
  ],
  "other_variants": [
    {
      "gene": "string",
      "chrom": "string",
      "pos": "number",
      "ref": "string",
      "alt": "string",
      "dp": "number",
      "annotation": "string"
    }
  ],
  "summary": {
    "num_frameshift": "number",
    "num_other": "number",
    "affected_genes": ["string"],
    "has_resistance_variants": "boolean"
  },
  "warnings": ["string"]
}
```

### 実装方針

```python
#!/usr/bin/env python3
# parse_cefiderocolFinder.py
import json, pandas as pd
from pathlib import Path

# Snakemakeオブジェクトからパスを取得
frameshift_tsv = snakemake.input.frameshift
other_tsv      = snakemake.input.other
species_id_path = snakemake.input.species_id
input_class_path = snakemake.input.input_class
out_json        = snakemake.output.json_report

# ── SKIPPEDチェック: ファイルが空ヘッダーのみ or モード/菌種ミスマッチ ──
# TSVが1行(ヘッダーのみ)であれば SKIPPED と判定

# ── TSVパース: pandas.read_csv(sep="\t") ──
# カラム: Name, Gene, CHROM, POS, ID, REF, ALT, QUAL, FILTER, AC, AF, AN,
#         BaseQRankSum, DP, ExcessHet, FS, InbreedingCoeff, MLEAC, MLEAF, MQ,
#         MQRankSum, QD, ReadPosRankSum, SOR, ANN, LOF, NMD

# ── 結果変換: 必要列のみ抽出しdict化 ──
# ── summary 生成: num_frameshift, num_other, affected_genes, has_resistance_variants ──
# ── status: PASS (バリアント0件含む実行完了) / FAIL (ツール実行エラー) / SKIPPED ──
```

### 検証チェックリスト

- [ ] short_read + 対応菌種サンプルで `cefiderocolFinder_result.json` が生成されること
- [ ] `status` キーが `PASS` / `SKIPPED` いずれかになること
- [ ] contigs モードで SKIPPED JSON が生成されること

---

## Phase 5: per_sample_report.py への統合

**変更ファイル**: `tarot-analyzer/workflow/scripts/per_sample_report.py`

### 変更内容

#### 1. モジュール読み込みリストへの追加 (L44-50付近)
```python
# 既存のモジュール読み込みブロックに追加
("cefiderocolFinder", snakemake.input.cefiderocolFinder),
```

#### 2. rule parse の input に cefiderocolFinder を追加
`stage1_cefiderocolFinder.smk` の `rule parse_cefiderocolFinder` の出力が
`per_sample_report.py` の input として必要。
`stage4_aggregate.smk` の `rule per_sample_report` の `input:` に追加:
```python
cefiderocolFinder = RESULTS_DIR / "{sample}" / "cefiderocolFinder" / "cefiderocolFinder_result.json",
```

#### 3. _build_cefiderocolFinder_section() 追加 (L366以降)
```python
def _build_cefiderocolFinder_section(modules):
    d = modules.get("cefiderocolFinder", {}) or {}
    status = d.get("status", "SKIPPED")
    if status == "SKIPPED":
        return {"status": "skipped", "reason": d.get("warnings", ["not applicable"])[0]}
    summary = d.get("summary", {})
    return {
        "status": "ok" if status == "PASS" else "fail",
        "num_frameshift": summary.get("num_frameshift", 0),
        "num_other": summary.get("num_other", 0),
        "affected_genes": summary.get("affected_genes", []),
        "has_resistance_variants": summary.get("has_resistance_variants", False),
        "frameshift_variants": d.get("frameshift_variants", []),
        "other_variants": d.get("other_variants", []),
    }
```

#### 4. レポートdictへのキー追加 (L74-80付近)
```python
"cefiderocolFinder": _build_cefiderocolFinder_section(modules),
```

### 検証チェックリスト

- [ ] `{sample}_report.json` に `cefiderocolFinder` キーが含まれること
- [ ] SKIPPED時に `{"status": "skipped"}` が入ること

---

## Phase 6: API result_parser.py への統合

**変更ファイル**: `tarot-analyzer/api/services/result_parser.py`

### 変更内容 (L35-55付近)

```python
# MODULE_FILE_MAP に追加
"cefiderocolFinder": "cefiderocolFinder/cefiderocolFinder_result.json",

# MODULE_CHECK_MAP に追加
"cefiderocolFinder": "cefiderocolFinder/cefiderocolFinder_result.json",
```

### 検証チェックリスト

- [ ] `GET /api/results/{job_id}/{sample}/module/cefiderocolFinder` が200を返すこと
- [ ] SKIPPED サンプルで `{"status": "skipped"}` が返ること

---

## Phase 7: フロントエンド統合

**変更ファイル**: `tarot-analyzer/frontend/src/pages/JobDetail.tsx`

### 変更内容

#### 1. MODULE_LABELS に追加 (L95-110付近)
```typescript
cefiderocolFinder: 'CefiderocolFinder',
```

#### 2. extractModuleRows に case 追加 (L158-195付近)
```typescript
case 'cefiderocolFinder': {
  const s = d.summary as Record<string, unknown> ?? {}
  const skipped = (d.status as string) === 'skipped'
  if (skipped) return [v('Status', 'N/A (not applicable)')]
  return [
    v('Frameshift variants', s.num_frameshift),
    v('Other variants',      s.num_other),
    v('Resistance variants', (s.has_resistance_variants as boolean) ? 'Yes ⚠' : 'No'),
  ]
}
```

#### 3. PipelineTimeline の _RULE_TO_MODULE マップ

`api/services/snakemake_runner.py` の `_RULE_TO_MODULE` に追加:
```python
"cefiderocolFinder":       "cefiderocolFinder",
"parse_cefiderocolFinder": "cefiderocolFinder",
```

### 検証チェックリスト

- [ ] 対応菌種 short_read サンプルの JobDetail に CefiderocolFinder カードが表示されること
- [ ] Frameshift / Other 件数が正しく表示されること
- [ ] 非対応 (SKIPPED) サンプルで "N/A" 表示になること

---

## 実装順序と依存関係

```
Phase 1 (手動/リモート)
    ↓
Phase 2 (config.yaml)
    ↓
Phase 3 (Snakemakeルール + Snakefile include)
    ↓
Phase 4 (parse_cefiderocolFinder.py)
    ↓
Phase 5 (per_sample_report.py + stage4_aggregate.smk)
    ↓
Phase 6 (result_parser.py)
    ↓
Phase 7 (JobDetail.tsx + snakemake_runner.py)
```

## 重要な注意事項

1. **入力モード対応状況**:
   - `short_read` / `hybrid`: 実リードをそのまま使用 ✓
   - `long_read`: Flye/DeChat pipeline の `contigs.fasta`（**medaka polish + dnaapler 済み**）→ wgsim で擬似 FASTQ ✓
   - `assembly_complete`: `input/contigs.fasta` → wgsim で擬似 FASTQ ✓
   - その他: SKIPPED
2. **wgsim は py39 で実行**: CefiderocolFinder conda env には含まれないため、ルール shell 内で py39 に切替えて wgsim を実行し、その後 CefiderocolFinder env に切替える (二段階 conda switch)
3. **wgsim 一時ファイルは実行後に自動削除**: `wgsim_R1.fastq` / `wgsim_R2.fastq` はストレージを圧迫しないよう shell 末尾で rm
4. **GATK は手動ダウンロード必須**: ライセンス制約のため conda に含まれていない
5. **conda 環境が非常に重い**: 初回構築に時間がかかる (PyTorch, PyMC, snpEff を含む)
6. **参照ゲノムはリモートサーバーに手動配置**: `_sync_pipeline_files()` での自動同期は非現実的
7. **`workflow/` sync 対象**: `stage1_cefiderocolFinder.smk` は `_sync_pipeline_files()` で自動転送される
8. **wgsim のカバレッジ**: デフォルト 50x。ゲノムサイズを `seqkit stats` で取得してリード数を自動計算するため、ゲノムサイズによらず均一なカバレッジが得られる
