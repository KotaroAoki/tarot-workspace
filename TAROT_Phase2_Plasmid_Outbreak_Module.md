# TAROT-Analyzer Phase 2: Plasmid HGT Outbreak Module

> **目的**: カルバペネマーゼ産生腸内細菌目細菌(CPE)における、薬剤耐性プラスミドの水平伝播(HGT)が関連するアウトブレイクを TAROT-Analyzer で自動解析できるようにするための、設計・実装ドキュメント。Claude Code への引き継ぎ用。

---

## 0. コンテキスト(Claude Code へのオリエンテーション)

- 既存パイプライン: **TAROT-Analyzer Phase 1a** が完了済み。
  - Snakemake ベース CLI
  - 既存ツール: **QUAST, Mash, MLST, ABRicate, ResFinder, PlasmidFinder**
- 開発中: **Phase 1b** — 出力パーサ統一 + SQLite スキーマ化
- 環境: WSL2 (Ubuntu) + conda/mamba。ONT 長鎖アセンブリは Flye / Raven / Autocycler を試行中
- 本ドキュメントは **Phase 2(Plasmid HGT Outbreak Module)** を Phase 1b の上に積む構成

---

## 1. 設計の根拠(英語論文ベース)

### 1.1 なぜプラスミド専用レイヤーが必要か

- **Singapore 全国サーベイランス (Nat Commun 2025)**: 1,088 株の CPE / 1,115 閉環プラスミド。blaKPC-2 陽性 PC1 プラスミドの **60.7%**、blaNDM-1 陽性 PC2 プラスミドの **59.4%** が**プラスミド介在性 HGT で carbapenemase を獲得**。残り約 40% がクローン依存性垂直伝播。
  - → **クローン解析(cgMLST/SNP)だけでは伝播の半分以上を見逃す**
- **NYC 10 年 CRE データ (Genome Res 2024)**: 605 株 CRE、435 株 hybrid assembly。blaKPC の拡散はクローン伝播と MGE 介在性 HGT の両方が複雑なネットワークを形成
- **HGT 研究の急増**: 2013–2024 のレビューで臨床×環境間 HGT 事例 13 報、うち半数は直近 3 年以内

### 1.2 ベンチマーク的パイプラインと採用するパラメータ

#### Münster/Ridom "Real-time plasmid transmission detection pipeline" (Microbiology Spectrum 2024)

**TAROT が骨格として模倣すべき業界標準**:
- ローカル Mash プラスミド DB
- **Mash sketch size = 10,000 / distance threshold = 0.001** で Early Warning Alert (EWA)
- cgMLST でクローン伝播
- MOB-suite + NCBI AMRFinderPlus + MobileElementFinder + pyGenomeViz + MUMmer

#### Berlin NDM-1 K. pneumoniae 研究 (2025)

- MOB-suite v3.1.8 + AMRFinderPlus v3.11.26
- TaDReP で hybrid assembly からリファレンスプラスミド構築
- short-read を reference plasmid に align してプラスミドレベル近縁性を SNP 単位で評価

#### Royal Prince Alfred Hospital サーベイランス定義 (ICE 2024)

**TAROT の outbreak status 定義として採用**:
- "possible outbreak": ≥1 isolate + 疫学リンク
- "probable outbreak": **同じ CPE 遺伝子を保有する遺伝学的に連結した isolate、または一致するプラスミド(identity & coverage > 95%)が検出**
- "confirmed outbreak": ゲノム + 疫学の両方のリンク

### 1.3 ツール選択の根拠

| ツール | 役割 | 強み |
|---|---|---|
| **MOB-suite (recon/typer/cluster)** | プラスミド contig 分類・型別・OTU 命名 | primary cluster code、Münster パイプラインと互換、novel プラスミドの自動命名 (novel_{md5}) |
| **AMRFinderPlus** | AMR 遺伝子検出(ABRicate からの置換 or 併用) | NCBI キュレーション、carbapenemase 文脈情報 |
| **MobileElementFinder + ISEScan** | IS26, Tn4401 等の MGE 文脈 | KPC は Tn4401 の解析必須 |
| **pling** | プラスミド clustering の高精度層 | **DCJ-Indel + containment**、TE-aware、IS26 promiscuity の偽陽性を除去 |
| **PPanggolin (+ panRGP)** | プラスミドクラスタごとの pangenome | persistent/shell/cloud 分割、carbapenemase 周辺の genomic islands 検出 |
| **chewBBACA** | cgMLST(クローン伝播) | SeqSphere+ 互換スキーマ |
| **snippy + snippy-core** | クローン SNP 解析 | ST 内の高解像度伝播 |
| **pyGenomeViz** | プラスミドペアワイズ可視化 | Münster 互換、HTML レポート埋め込み可 |

### 1.4 既存ツールの問題点と対策

**Mash 単独の限界**:
- 再配列を無視 → 近縁性を過大評価
- 遺伝子の獲得/喪失を過剰ペナルティ → 過小評価
- TE promiscuity → 無関係プラスミドの過剰クラスタリング
- → **pling の DCJ-Indel で補正**

**SNP しきい値の限界**:
- エンデミック株では不正確
- 種別・ST 別の経験的分布が必要
- → TAROT に **動的しきい値機能**を実装

**アセンブリ品質**:
- short-read のみではプラスミドが断片化し、染色体/プラスミド文脈が不明
- → **長鎖シーケンスの取り込みは必須**(既存 ONT パイプラインと直結)

---

## 2. アーキテクチャ

### 2.1 5層構成

```
┌─────────────────────────────────────────────────────────────┐
│ Layer E: 出力・可視化・SQLite                                │
│   pyGenomeViz / Cytoscape JSON / microreact / HTML report    │
├─────────────────────────────────────────────────────────────┤
│ Layer D: クローン vs プラスミド伝播の二元評価                │
│   cgMLST + snippy ─┐                                         │
│                     ├─→ outbreak_cluster 統合判定           │
│   Mash + pling ────┘                                         │
├─────────────────────────────────────────────────────────────┤
│ Layer C: pangenome 解析                                      │
│   PPanggolin / panRGP / panModule(プラスミドクラスタごと)  │
├─────────────────────────────────────────────────────────────┤
│ Layer B: プラスミドクラスタリング(across isolates)         │
│   ① Mash dist < 0.001 (EWA)                                 │
│   ② MOB-cluster primary cluster code (OTU)                  │
│   ③ pling containment + DCJ-Indel (高精度)                  │
├─────────────────────────────────────────────────────────────┤
│ Layer A: per-isolate プラスミド抽出・型別                    │
│   MOB-recon → MOB-typer + AMRFinderPlus + MobileElementFinder│
│   ONT 長鎖は Flye/Autocycler で閉環化(既存パイプライン)    │
└─────────────────────────────────────────────────────────────┘
              ↑
   Phase 1a (QUAST, Mash, MLST, ABRicate, ResFinder, PlasmidFinder)
   Phase 1b (output parser unification, SQLite schema)
```

---

## 3. SQLite スキーマ拡張(Phase 1b 上に追加)

```sql
-- プラスミド単位のレコード
CREATE TABLE plasmid (
    plasmid_id          TEXT PRIMARY KEY,
    isolate_id          TEXT NOT NULL,
    mob_cluster_id      TEXT,
    inc_type            TEXT,        -- e.g. IncFIB(pQil), IncM1
    mob_type            TEXT,        -- relaxase MOB type
    mpf_type            TEXT,        -- mating pair formation type
    conjugative         TEXT,        -- conjugative / mobilizable / non-mobilizable
    size_bp             INTEGER,
    circular            BOOLEAN,
    amr_genes_json      TEXT,        -- JSON list
    carbapenemase_genes TEXT,        -- comma-separated
    assembly_source     TEXT,        -- short-read / long-read / hybrid
    FOREIGN KEY (isolate_id) REFERENCES isolate(isolate_id)
);

-- プラスミドクラスタ(method ごとに行を分ける)
CREATE TABLE plasmid_cluster (
    cluster_id              TEXT PRIMARY KEY,
    method                  TEXT NOT NULL CHECK(method IN ('MOB', 'pling_community', 'pling_subcommunity', 'mash')),
    representative_plasmid  TEXT,
    member_count            INTEGER,
    carbapenemase_genes     TEXT,
    FOREIGN KEY (representative_plasmid) REFERENCES plasmid(plasmid_id)
);

CREATE TABLE plasmid_cluster_membership (
    cluster_id  TEXT NOT NULL,
    plasmid_id  TEXT NOT NULL,
    PRIMARY KEY (cluster_id, plasmid_id),
    FOREIGN KEY (cluster_id) REFERENCES plasmid_cluster(cluster_id),
    FOREIGN KEY (plasmid_id) REFERENCES plasmid(plasmid_id)
);

-- プラスミド間距離
CREATE TABLE plasmid_distance (
    p1_id            TEXT NOT NULL,
    p2_id            TEXT NOT NULL,
    mash_dist        REAL,
    dcj_indel_dist   INTEGER,
    containment      REAL,
    jaccard          REAL,
    PRIMARY KEY (p1_id, p2_id),
    FOREIGN KEY (p1_id) REFERENCES plasmid(plasmid_id),
    FOREIGN KEY (p2_id) REFERENCES plasmid(plasmid_id)
);

-- pangenome partition (PPanggolin)
CREATE TABLE pangenome_partition (
    plasmid_id   TEXT NOT NULL,
    gene_family  TEXT NOT NULL,
    partition    TEXT CHECK(partition IN ('persistent', 'shell', 'cloud')),
    rgp_id       TEXT,    -- panRGP region of genomic plasticity
    PRIMARY KEY (plasmid_id, gene_family),
    FOREIGN KEY (plasmid_id) REFERENCES plasmid(plasmid_id)
);

-- 伝播イベント
CREATE TABLE transmission_event (
    event_id          INTEGER PRIMARY KEY AUTOINCREMENT,
    event_type        TEXT CHECK(event_type IN ('clonal', 'plasmid', 'both')),
    src_isolate       TEXT NOT NULL,
    dst_isolate       TEXT NOT NULL,
    evidence_score    REAL,
    snp_distance      INTEGER,
    cgmlst_distance   INTEGER,
    plasmid_id_shared TEXT,
    notes             TEXT,
    FOREIGN KEY (src_isolate) REFERENCES isolate(isolate_id),
    FOREIGN KEY (dst_isolate) REFERENCES isolate(isolate_id)
);

-- アウトブレイク
CREATE TABLE outbreak_cluster (
    outbreak_id      INTEGER PRIMARY KEY AUTOINCREMENT,
    outbreak_type    TEXT CHECK(outbreak_type IN ('clonal', 'plasmid', 'both')),
    status           TEXT CHECK(status IN ('possible', 'probable', 'confirmed')),
    start_date       DATE,
    end_date         DATE,
    carbapenemase    TEXT,
    species_involved TEXT,
    notes            TEXT
);

CREATE TABLE outbreak_isolate (
    outbreak_id  INTEGER NOT NULL,
    isolate_id   TEXT NOT NULL,
    PRIMARY KEY (outbreak_id, isolate_id),
    FOREIGN KEY (outbreak_id) REFERENCES outbreak_cluster(outbreak_id),
    FOREIGN KEY (isolate_id) REFERENCES isolate(isolate_id)
);

-- isolate テーブルに source_type を追加(マイグレーション)
-- ALTER TABLE isolate ADD COLUMN source_type TEXT
--     CHECK(source_type IN ('clinical', 'screening', 'environmental'));
```

---

## 4. config.yaml 追加項目

```yaml
plasmid_outbreak:
  # Mash-based EWA
  mash_distance_threshold: 0.001
  mash_sketch_size: 10000
  mash_size_correction: true

  # pling (実装済み 2026-05-28: Layer B.1 ③ 高精度クラスタリング層)
  # リモート WSL2 サーバーで事前に conda 環境構築が必要 (公式手順):
  #   方法A (bioconda 経由・推奨):
  #     mamba create -n pling_env -c bioconda -c conda-forge pling
  #     conda activate pling_env && pling --version
  #   方法B (ソースから):
  #     cd ~/program/pling && mamba env create -n pling_env -f env.yaml
  #     conda activate pling_env && python -m pip install . && pling --version
  # ソルバーは GLPK (オープンソース) がデフォルト。Gurobi 利用には別途ライセンス必要。
  pling_enabled: true
  pling_conda_env: "pling_env"          # mob_suite_env と同パターン (手動構築)
  pling_threads: 8
  pling_containment_threshold: 0.5      # sourmash containment 距離閾値
  pling_dcj_threshold: 4                # DCJ-Indel 距離閾値 (Sheppard et al. 仕様)
  pling_output_type: "both"             # community + subcommunity 両方出力
  # 3手法 (mash/mob/pling) のうち何個一致で `confirmed` cluster とするか
  consensus_min_methods: 2              # 2/3一致=confirmed, 1/3=probable, 0=single

  # cgMLST(種別)
  cgmlst_threshold:
    Klebsiella_pneumoniae: 10
    Escherichia_coli: 20
    Enterobacter_cloacae: 15
    Citrobacter_freundii: 15
    Serratia_marcescens: 15

  # クローン SNP しきい値(動的しきい値が望ましいが、初期値)
  snp_threshold:
    default: 20
    Klebsiella_pneumoniae: 16   # Wang 2022 ICU outbreak より

  # 監視対象 carbapenemase
  carbapenemase_genes:
    - blaKPC
    - blaNDM
    - blaIMP        # 日本では IMP-6, IMP-1 が重要
    - blaVIM
    - blaOXA-48
    - blaOXA-181
    - blaOXA-232

  # MOB-suite
  mob_recon_min_length: 1000

  # 解析対象とする最小プラスミド数(クラスタ・pangenome)
  min_cluster_size: 2
  min_pangenome_cluster_size: 5
```

---

## 5. Snakemake ルール構成

```
workflow/
├── Snakefile
├── rules/
│   ├── 01_qc_assembly.smk          # 既存 (Phase 1a)
│   ├── 02_typing.smk                # 既存 (MLST, PlasmidFinder)
│   ├── 03_amr.smk                   # 既存 (ABRicate, ResFinder) → AMRFinderPlus 追加
│   ├── 10_plasmid_recon.smk         # 新規: MOB-recon, MOB-typer
│   ├── 11_mge.smk                   # 新規: MobileElementFinder, ISEScan
│   ├── 12_plasmid_distance.smk      # 新規: Mash sketch & dist
│   ├── 13_plasmid_clustering.smk    # 新規: MOB-cluster, pling
│   ├── 14_pangenome.smk             # 新規: PPanggolin per cluster
│   ├── 20_cgmlst.smk                # 新規: chewBBACA
│   ├── 21_clonal_snp.smk            # 新規: snippy, snippy-core
│   ├── 30_integrate.smk             # 新規: SQLite 統合 + outbreak 推論
│   └── 40_report.smk                # 新規: HTML report 生成
└── scripts/
    ├── populate_plasmid_db.py
    ├── infer_transmission.py
    ├── infer_outbreak.py             # Royal Prince Alfred 定義の実装
    └── generate_report.py
```

### 主要ルールのスケッチ

```python
# rules/10_plasmid_recon.smk
rule mob_recon:
    input:
        assembly = "results/assembly/{sample}/{sample}.fasta"
    output:
        directory("results/mob_recon/{sample}/"),
        report = "results/mob_recon/{sample}/contig_report.txt"
    conda: "../envs/mob_suite.yaml"
    shell:
        """
        mob_recon --infile {input.assembly} \
                  --outdir {output[0]} \
                  --num_threads {threads} \
                  --min_length {config[plasmid_outbreak][mob_recon_min_length]} \
                  --force
        """

# rules/12_plasmid_distance.smk
rule mash_sketch_plasmids:
    input:
        expand("results/mob_recon/{sample}/plasmid_*.fasta", sample=SAMPLES)
    output:
        "results/mash/all_plasmids.msh"
    shell:
        "mash sketch -s {config[plasmid_outbreak][mash_sketch_size]} -o {output} {input}"

rule mash_dist_plasmids:
    input:
        "results/mash/all_plasmids.msh"
    output:
        "results/mash/plasmid_distances.tsv"
    shell:
        "mash dist {input} {input} > {output}"

# rules/13_plasmid_clustering.smk
rule pling:
    input:
        plasmid_list = "results/mob_recon/all_plasmids.txt"
    output:
        directory("results/pling/")
    conda: "../envs/pling.yaml"
    shell:
        """
        pling align --genomes_list {input.plasmid_list} \
                    --outdir {output} \
                    --containment_distance {config[plasmid_outbreak][pling_containment_threshold]} \
                    --dcj {config[plasmid_outbreak][pling_dcj_threshold]} \
                    --output_type both
        """

# rules/14_pangenome.smk
rule ppanggolin_per_cluster:
    input:
        cluster_members = "results/pling/subcommunity_{cluster}.txt"
    output:
        directory("results/ppanggolin/{cluster}/")
    conda: "../envs/ppanggolin.yaml"
    shell:
        """
        ppanggolin workflow --anno {input.cluster_members} \
                            --output {output} \
                            --cpu {threads}
        ppanggolin rgp -p {output}/pangenome.h5
        """
```

---

## 6. 実装ロードマップ

| Phase | 目安 | 内容 | 完了条件 |
|---|---|---|---|
| 2.0 | 1 か月 | MOB-suite (recon/typer/cluster) + AMRFinderPlus を Snakemake 統合、SQLite スキーマ拡張 | 既存テストデータで MOB-recon の出力が DB に入る |
| 2.1 | 1 か月 | Mash-based プラスミドアラート(Münster 方式)、chewBBACA cgMLST 統合 | UPMC Presbyterian dataset で再現できる |
| **2.2** ✅ | 1–2 か月 | **pling (containment + DCJ-Indel) 統合、3-method consensus 判定 (mash/mob/pling)**、Cytoscape 出力、Russian Doll dataset で検証 | **実装完了 (2026-05-28): stage2_plasmid_cluster.smk に run_pling/parse_pling_clusters 追加、merge で consensus_level=confirmed/probable 判定、フロント表示 (PlasmidProfileSection / OutbreakAlertsCard) 完了。Russian Doll 検証は次フェーズ** |
| 2.3 | 1 か月 | PPanggolin / panRGP 統合(プラスミドクラスタごとの pangenome) | persistent/shell/cloud 分類が DB に入る |
| 2.4 | 1 か月 | HTML report 自動生成(pyGenomeViz, microreact 出力)、Singapore dataset で大規模検証 | 1,000+ プラスミドでスケールする |
| 2.5 | — | 論文化、TAROT クラウド版への組み込み | — |

**最初のスプリント = Phase 2.0** から着手。最も ROI が高い。

---

## 7. 検証データセット

論文化を視野に、**publicly available なベンチマークデータセット**を使用:

1. **'Russian Doll' dataset** (Sheppard et al., Sussex hospital, blaKPC) — pling 主要ベンチマーク
2. **UPMC Presbyterian dataset** — 2021–2023、15 例 / 19 株 / 7 菌種の blaNDM-5 マルチ菌種アウトブレイク、Illumina + ONT MinION R9.4.1 公開済み、Münster パイプラインの第二検証セット
3. **Singapore dataset** (Nat Commun 2025) — 1,115 閉環プラスミド、PC1/PC2 クラスタリングの再現性確認用
4. **NYC 10-year CRE dataset** (Genome Res 2024) — 435 hybrid assembly、blaKPC ダイナミクス

---

## 8. 重要な落とし穴(Claude Code 実装時の注意)

1. **アセンブリ品質**: short-read のみではプラスミドが断片化。必ず長鎖との hybrid または long-read 単独 + 高精度ポリッシュを推奨。MOB-recon の出力品質は assembly に直結する。
2. **トランスポゾン誤クラスタリング**: IS26 / Tn4401 は無関係プラスミド同士を「似ている」と誤判定。**pling の TE-aware 設計が必須**、または carbapenemase ± transposase 領域をマスクしてから Mash 距離。
3. **SNP しきい値の限界**: 固定しきい値ではなく、種別・ST 別の経験的分布で動的に。`snp_threshold` 設定は初期値であり、データ蓄積に応じて更新する仕組みが望ましい。
4. **環境サンプル**: シンク等の環境分離株が伝播源となる事例(IncM1 vehicle)があるため、`isolate.source_type` を最初から実装。
5. **MOB-suite DB 初期化**: 初回実行時は `mob_init` でデータベースのダウンロード・sketch・blast DB セットアップが必要。Snakemake では setup rule として独立させる。
6. **PPanggolin の用途限定**: 第一義は種レベル pangenome。**プラスミドクラスタごとに分けて適用**することを忘れずに。プラスミド全体に対して 1 回だけ走らせるのは意味が薄い。
7. **conda 環境分離**: MOB-suite, pling, PPanggolin, chewBBACA はそれぞれ依存関係が複雑。Snakemake の `conda:` 指示子で**ルールごとに環境を分離**する。

---

## 9. 参考論文(主要なもの、Claude Code が必要に応じて参照)

- **Münster real-time pipeline**: Microbiology Spectrum 2024, doi 10.1128/spectrum.02100-24
- **pling**: Microbiology Society / Microbial Genomics 2024, doi 10.1099/mgen.0.001300, GitHub: iqbal-lab-org/pling
- **MOB-suite**: Microb Genom 2018, GitHub: phac-nml/mob-suite
- **PPanggolin**: GitHub: labgem/PPanGGOLiN, docs: ppanggolin.readthedocs.io
- **panRGP**: bioRxiv 2020, doi 10.1101/2020.03.26.007484
- **Singapore CPE nationwide**: Nat Commun 2025, doi 10.1038/s41467-025-64515-7
- **NYC CRE 10-year**: Genome Res 2024
- **Royal Prince Alfred surveillance**: ICE 2024, doi 10.1017/ice.2023.205
- **Berlin NDM-1 K. pneumoniae**: 2025, PMC12492617
- **CPE plasmid dissemination review**: 2025, PMC12029780
- **IMP carbapenemase global spread**: Nat Commun 2025, doi 10.1038/s41467-025-66874-7

---

## 10. Claude Code への最初の指示(推奨)

```
@TAROT_Phase2_Plasmid_Outbreak_Module.md を読んで、Phase 2.0 から実装を始めます。
具体的には以下のタスクを順に進めてください:

1. SQLite スキーマ拡張のマイグレーションスクリプト作成
   - 既存の Phase 1b スキーマに対する ALTER / CREATE TABLE
   - alembic か単純な SQL マイグレーションでもよい

2. MOB-suite を Snakemake に統合する rule の作成
   - rules/10_plasmid_recon.smk
   - envs/mob_suite.yaml(conda env)
   - mob_init を setup rule として独立

3. AMRFinderPlus を ABRicate と並列に統合
   - rules/03_amr.smk に追加(既存を壊さない)
   - envs/amrfinderplus.yaml

4. MOB-recon / MOB-typer 出力を SQLite に流し込むパーサ
   - scripts/populate_plasmid_db.py

5. 既存のテストデータ(K. pneumoniae 等)で動作確認

各ステップで pytest テストを書きながら進めてください。
作業前に既存の Snakefile, config.yaml, scripts/, rules/ を確認して、
コーディング規約に合わせてください。
```

---

**作成日**: 2026-05-27
**ベースとなった会話**: Claude (claude.ai) との設計議論セッション
**次のアクション**: Claude Code でこのドキュメントを読み込み、Phase 2.0 から実装開始
