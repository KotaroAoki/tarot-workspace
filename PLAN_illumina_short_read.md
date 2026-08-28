# PLAN: Illumina ショートペアエンドリード対応

作成: 2026-08-19 / 状態: **計画のみ (未実装)**

## 0. 前提となる確認結果

短鎖リード対応の「骨格」は v2.0 (`7dde16c` / `4350fdd`) で既にコードに入っているが、
**一度も実行されたことがない**。NAS 全 7 アカウント 515 検体で `assembly/short_read/`
は 0 件、git 履歴上も SPAdes ルールは heartbeat 追加 (`1c8621e`) 以降変更なし。
= 半分だけ埋まった未検証コードという状態。

### 既にあるもの

| 層 | 実装状況 |
|---|---|
| 入力判定 | `classify_input.py` が `_R1/_R2` と `_1/_2` を検出 → `mode=short_read` / `hybrid` |
| アセンブリ | `stage1_spades_assembly.smk` = fastp → SPAdes `--isolate` → seqkit 最小長 500 bp |
| DAG 分岐 | `Snakefile.get_input_fasta()` が short_read/hybrid → `assembly/short_read/contigs.fasta` |
| アップロード | `api/routers/upload.py` / `DropZone.tsx` とも `.fastq(.gz)` 受け入れ済み |
| API | rule→module マップに `spades_assembly`、`sample_modes` 追跡、結果パス探索も short_read 候補済み |
| UI | `PipelineTimeline` が "Assembly (SPAdes)"、`SampleDetail` もモード別表示 |
| contig 名 | `_CONTIG_RE = (contig\|tig\|node\|scaffold)` で SPAdes の `NODE_1_...` を吸収済み (workflow / frontend 両方)。`cov[:_]` の被覆パースも `cov_28.4` にマッチ |
| リード直接利用 | SeqSero2 / cefiderocolFinder は short_read の実リード経路を実装済み |

### 決定事項 (2026-08-19, ユーザー判断)

1. **cgSNP**: Illumina でも動かす。BAM DB は **同じ `{species}/{群}/` に入れ、platform タグを付ける**。
2. **hybrid**: 現状どおり short_read 優先のまま。**表示とログで「長鎖リードは未使用」と明示**する。
3. **入力データ**: 自施設の生 PE FASTQ (MiSeq/NextSeq 等) と 公共データ (SRA 等) の PE FASTQ。
4. **プラスミド DB**: 短鎖リード由来は **DB に登録せず照会のみ (read-only)**。

---

## 1. Phase 0 — 実測 (実装なし・最優先)

未実行コードなので、机上で直すより先に「どこで落ちるか」を測る。

- [ ] ワーカー 3 台 (honban / kibanb / tugrip) で py39 の `spades.py --version` / `fastp --version` /
      搭載 RAM を確認。`docs/MULTISERVER_DEPLOYMENT.md:67` は両方入っている前提だが実機未確認。
      **#28 の教訓: ワーカー間のツール差分は「割り当て次第で成否が変わる」形で表面化する。**
- [ ] Illumina PE 1 検体 (E. coli 等) を 1 サンプルだけ投入し、素の状態でどこまで通るか記録する。
- [ ] 取得すべき数値: SPAdes の実 RAM ピーク / 実時間 / `spades_output` の残骸サイズ /
      QUAST の N50・contig 数 / molecule 判定の内訳 (chromosome / plasmid / unclassified の本数)。

この結果が Phase 1〜3 の閾値設計の入力になる。

---

## 2. Phase 1 — アセンブリ経路の実用化

### 1-1. SPAdes ルールの作り込み (`workflow/rules/stage1_spades_assembly.smk`)

- **メモリ上限**: `-m` 未指定 = SPAdes 既定 250 GB。`TAROT_SAMPLES_PER_WORKER=2` (#25) との
  掛け算で OOM しうる。`assembly.short_read.memory_gb` を config に追加し、
  ワーカー RAM ÷ 同時サンプル数から渡す。
- **`--only-assembler` の要否**: 現状 BayesHammer が走る (時間・ディスク)。Phase 0 の実測で判断。
- **低被覆 contig フィルタ**: shovill の `--mincov 2` 相当が無い。コンタミ/アーティファクト contig が
  残ると **AMR 遺伝子の偽陽性**になる。SPAdes ヘッダの `cov_` を見て閾値未満を落とす。
- **EXIT trap で中間ファイル削除**: 現状 `rm -f` は成功パス末尾のみ。
  失敗時に `trimmed_R*.fq` と `spades_output/` (補正済みリード + K21/K33/K55) が残る。
  [[project_assembly_intermediate_fastq_leak]] と同型の再発なので flye と同じ形にする。
- **ヘッダ正規化**: SPAdes ヘッダから疑似 `assembly_info.txt` (name / length / cov / circ=N) を作り、
  `annotate_assembly_headers.py` を通して `contig_N_length:X_cov:Y_linear` に統一する。
  `contig_key` は既に両対応なので**必須ではない**が、Bakta 復元 (#22) や表示の一貫性のために有用。
- **threads**: `assembly.short_read.threads: 24` 固定は #25 のコア頭割りと不整合。
  Snakemake が `--cores` で丸めるので事故にはならないが、意図を config で表現する。
- **contigs か scaffolds か**: 現状 contigs.fasta。維持 (N 連結を持ち込まない)。

### 1-2. 中間ファイル掃除の拡張 (`api/services/snakemake_runner.py`)

`_sweep_intermediates_cmd` が `*/assembly/long_read/*` しか見ていない。
`*/assembly/short_read/*` を追加し、`spades_output/` と `trimmed_R*.fq` を対象に入れる。
**`contigs.fasta` / `assembly_stats.txt` / `fastp.json` は残すこと。**

### 1-3. hybrid の明示 (決定 2)

- `classify_input` / `get_input_fasta` の挙動は変えない。
- SPAdes ルールのログと `input_class.json` に `long_reads_unused: true` 相当を残す。
- `PipelineTimeline` / `SampleDetail` の hybrid 表示に「長鎖リードは未使用 (SPAdes 単独)」を併記。

---

## 3. Phase 2 — リード QC と被覆 (現状「未対応」と自白している箇所)

`SampleDetail.tsx:777` に「short-read のリード QC は未対応 (今後 fastp 連携予定)」とある。
`fastp.json` は既に生成されているのに誰も読んでいない。

- [ ] `parse_fastp.py` (新規) で `fastp.json` → `assembly/short_read/read_qc.json`。
      before/after のリード数・総塩基・Q20/Q30・duplication・insert size peak。
- [ ] **推定被覆** = トリム後総塩基 ÷ `genome_size_map[species_id]`。
      ゲノムサイズは **トップレベル `genome_size_map` = 単一の真実源** を引く (#19 / #24 と同じ)。
- [ ] 閾値 (`assembly.short_read.min_depth_warn`, 既定 30×) 未満は WARN。
      **「検査できていない」を「陰性」にしない** (#28) — 被覆不足は明示する。
- [ ] `per_sample_report._build_*` に `read_qc` セクションを追加し、UI の「未対応」文言を置換。
      ONT の NanoPlot セクションと同じ場所に出す。
- [ ] `parse_fastp.py` の `main()` は **`if "snakemake" in globals():` でガード** (#24)。

---

## 4. Phase 3 — QC / molecule 判定の短鎖リード較正

### 3-1. QUAST 閾値 (`workflow/scripts/parse_quast.py`)

現状 N50 < 10 kb / contigs > 500 で WARN = ONT 較正。Illumina では常時発火する。
入力モード別の閾値にする (例: short_read = N50 < 30 kb / contigs > 500 を WARN、
contigs > 1000 を強い WARN)。Phase 0 の実測で数値を決める。

### 3-2. molecule 判定 (#19) の劣化への対処

短鎖リードでは **circularity.json / GFA 連結成分 / 環状性がすべて無い**ため、
使える証拠は MOB-recon + PlasmidFinder + 被覆/GC のみに痩せる。加えて:

- `backbone` ガードは最大 contig 1 本しか守らない (断片化した染色体は無防備)
- `matches_chromosome_profile` は `chromosome_profile_min_size: 100_000` 以上にしか効かない

→ **誤ってプラスミドに昇格する方向ではなく「判定不能」が増える方向**に倒れるので危険度は低いが、
表示は劣化する。対応:

- [ ] `molecule_classification.json` に `assembly_platform` / `evidence_available` を持たせ、
      「環状性の証拠が無い」ことを**明示**する (`unclassified` を「プラスミドではない」と読ませない)。
- [ ] short_read 時の `chromosome_profile_min_size` を下げるか、
      「backbone と被覆・GC が一致する contig 群」を染色体側に寄せる補助証拠を検討。
      **判定式は `classify_molecules.py` のみに置くこと** (#19 の二重化事故の再発防止)。
- [ ] UI (`plasmidMap` 系 / SampleDetail) に「短鎖リードのため環状性判定なし」を表示。

---

## 5. Phase 4 — cgSNP の Illumina 対応 (決定 1)

`stage2_core_snp.smk:106` が `MODE != long_read` で無条件 SKIPPED。
構造上は **むしろ簡単**で、`run_core_snp_map.py` の Phase 1〜4
(fastplong → DeChat → wgsim = 「擬似 PE を作る」工程) を
「実 PE に fastp」へ差し替えれば、Phase 5 以降 (stringMLST → BWA → BAM DB → phylo) は流用できる。

### 5-1. マッピング経路

- [ ] `run_core_snp_map.py` に `--short-reads R1 R2` 経路を追加。
      fastp (品質・アダプタ) → 目標被覆へ間引き (`core_snp.target_depth` を流用) → そのまま Phase 5 へ。
- [ ] **`bwa bwasw` ではなく `bwa mem` (paired) を使う**。bwasw は 150 bp PE には不適
      (CLAUDE.md #23 でも既に指摘済み)。ONT 側の既存 BAM は bwasw のままにする
      (差し替えると既存 BAM DB の再構築が必要 = #23 の通り別案件)。
- [ ] stringMLST は**実リードをそのまま**渡せる (本来の想定入力)。wgsim 不要。
- [ ] `mapping_info.json` に `platform: "illumina" | "ont"` を書く。
      **系統樹だけ作り直す経路 (`--allowed-rules core_snp_phylo`) は mapping_info.json しか
      手がかりが無い** (#35 の群と同じ理由) ので必須。

### 5-2. BAM DB (決定 = 同じ群 + platform タグ)

- [ ] `store_bam_to_db()` が `metadata.json` に `platform` を記録。
      書き込みは **一時ファイル + `os.replace` のアトミック置換** (#25)。
- [ ] `run_core_snp_phylo.py` は群内の全 BAM を従来どおり集める。
      `core_snp_result.json` に各 tip の platform を載せる。
- [ ] **UI で明示**: `PhyloTree` / `CoreSnpSection` / 距離行列で ONT 由来と Illumina 由来を区別表示し、
      **プラットフォームを跨ぐペアの距離には注意書きを出す**。
- [ ] **較正の実測を必ず行う (重要)**: 同一分離株を ONT と Illumina の両方で読み、
      ペアワイズ距離を測る。ONT の系統的エラーは全 ONT 検体で共通なので相殺されるが、
      Illumina を混ぜるとその相殺が効かず **ONT×Illumina のペアだけ距離が膨らむ**可能性がある。
      実測値が出るまでは cross-platform の距離を「同一株判定」に使わない。
      [[project_lowcov_snp_artifact_signature]] の C↔G 過剰シグネチャも併せて確認する。
- [ ] `core_snp.min_core_fraction` (既定 0.3, #26) は Illumina では通常問題ないが、実測で確認。
- [ ] `localize_bams` の BAM キャッシュ (#26) は群単位なので**変更不要**。
- [ ] `api/services/snakemake_runner.py:1249` の `core_snp_status` pending 初期化が
      `long_read` 限定になっている → short_read も対象にする。
      **これを忘れると UI が cgSNP ブランチ自体を描画しない。**
- [ ] 参照ゲノム解決 (#29) は菌種依存で platform 非依存なので**変更不要**。

---

## 6. Phase 5 — プラスミド: 照会のみ (決定 4)

**調査で判明した重要な点**: `plasmid_outbreak.require_circular` は既定 `true` で、
短鎖リード contig は環状フラグを持たないため **自動的に DB 登録されない**。
つまり「read-only」は事実上すでに既定の挙動。**ただし副作用がある**:

`check_plasmid_outbreak.py` は **registration.json に載った `plasmid_uid` を起点に**
DB を引く設計なので、登録 0 件 = **照会も 0 件**になり、
`query.json` が「マッチ無し」として出る。これは #28 の無言の偽陰性そのもの
(「照会していない」が「該当なし」に見える)。

- [ ] `register_plasmids_to_db.py`: short_read のとき `status: "skipped"`,
      `reason: "short_read — read-only policy"` を明示的に書く (例外で落とさない)。
- [ ] `check_plasmid_outbreak.py`: 登録 uid が無くても
      **MOB-recon の `primary_cluster_id` を起点に DB を引ける**ようにする (照会のみ経路)。
- [ ] `query.json` に `registered: false` / `query_mode: "read_only"` を持たせ、
      UI (`OutbreakAlertsCard` / `PlasmidProfileSection`) に
      「DB 未登録・照会のみ (短鎖リード)」を明示する。
- [ ] `PlasmidDistanceMap` / pling クラスタリングは短鎖リード検体を母集団に入れない
      (断片化 contig が DCJ 距離を歪めるため)。除外理由を UI に出す。

---

## 7. 実装順序と検証

1. **Phase 0** (実測) → ここで得た数値で Phase 1〜3 の閾値を決める
2. **Phase 1**(アセンブリ) → 1 検体で end-to-end が通ることを確認
3. **Phase 2**(リード QC) → 被覆不足検体が WARN になることを確認
4. **Phase 3**(QC/molecule 較正) → 実データで判定内訳を確認
5. **Phase 4**(cgSNP) → **同一株の ONT/Illumina ペアで較正実測**してから本番投入
6. **Phase 5**(プラスミド照会) → 偽陰性が出ないことを確認

### 検証に使う原則 (既存の教訓)

- 判定は**出力ファイルの実在**で行う。**exit 0 でも空のことがある** (#28)。
- ガードを書くときは**そのツールが実際に書くファイル名を実物で確認**する (#28.2)。
- Snakemake の `script:` 用スクリプトは **必ず `if "snakemake" in globals():` ガード**を付ける (#24)。
- `backfill_sample_reports.py --force` は使わない。**該当セクションだけ差し替える** (#28)。
- 新モジュールの `main()` は純粋関数 (`build_result()`) に切り出し、
  Snakemake と backfill の**単一の真実源**にする。

## 8. 影響を受けないことを確認済みの箇所

- contig 名の正規化 (`node_N`) — workflow / frontend 両方が SPAdes 対応済み
- 結果ダウンロード / NAS アーカイブ / `audit_stale_outputs` — `assembly/short_read` を候補済み
- SeqSero2 / cefiderocolFinder の実リード経路 — 実装済み
- 参照ゲノム解決 (#29) / BAM キャッシュ (#26) / サブタイプ群 (#35) — platform 非依存
- dorado 経路 — ONT 専用、無関係

---

## 9. Phase 0 実測結果 (2026-08-19, job `20260819_163420_e668c614`)

検体: `TAS002_Illumina` = SRA **SRR12628569** (PE, read length 142 bp)。
同一アカウント (kaoki_stec) に `TAS002_ONT` (E. coli / ST11 / FimH82 = cgSNP 群 `Ecoli/11_H82`) が存在し、
**決定 1 のクロスプラットフォーム較正ペアになる**。
ワーカー: honban (216 GB / 64 cores)。オーケストレータは `--cores 24` (48 ÷ 2 サンプル枠) を渡した。

### 解決した論点 (計画から削除・修正するもの)

| 論点 | 実測結果 |
|---|---|
| `--only-assembler` の要否 | **不要**。SPAdes 4.2.0 のログが `Mode: ONLY assembling (without read error correction)` と出しており、**`--isolate` が既に BayesHammer を無効化している**。→ 補正済みリードの残骸は発生しない。 |
| fastp の `-w` / `--thread` 重複指定 | **無害**。fastp 1.1.0 はエラーにせず処理を継続した。修正不要 (整理はしてよい)。 |
| SPAdes の既定メモリ | **250 GB 固定ではなく「実機の RAM」を自動採用**していた (`Memory limit (in Gb): 216`)。→ 対策の必要性は変わらないが理由が変わる: kibanb/tugrip では各 SPAdes が **61 GB を丸ごと自分のものだと思い込む**ため、`samples_per_worker=2` で 2 本走ると合計 122 GB を宣言することになる。**明示 `-m` = RAM ÷ 同時サンプル数 は依然必須。** |
| `threads: 24` 固定 | 今回は `--cores 24` と偶然一致した。Snakemake が丸めるので事故は起きないが、**一致は偶然**なので頭割り値から導出する方針は維持。 |
| 低被覆 contig フィルタ | ログに `Coverage cutoff is turned OFF`。**未フィルタ確定**。ヘッダの `cov_` を見た後段フィルタが要る。 |

### 新たに分かったこと

- **SPAdes は GFA v1.2 のアセンブリグラフを出力する** (`Assembly graph output will use GFA v1.2 format`)。
  現状 `spades_output/` ごと捨てる想定だったが、`assembly_graph_with_scaffolds.gfa` を残せば
  **既存の GfaGraph ビューアが短鎖リードでも使える**。連結成分を molecule 判定の材料にもできる
  (ただし #19 のとおり `separate_component` は環状 contig にしか credit を与えないので誤発火はしない)。
  掃除ルール (Phase 1-2) では **GFA を残す**こと。
- ログストリームが `ConnectionResetError` で切断 → 「ログ切断 — 実行状態を再確認中」表示。
  これは [[project_monitor_stream_drop_false_failure]] の既知パターンで、ファイルベースの
  フォールバックが働いている。**短鎖リード固有の問題ではない。**

### 新たに見つかったバグ (要修正)

**`Core-genome SNP` が「完了」と表示される (実体は SKIPPED)**

短鎖リード検体では `core_snp_map` が `mapping.done` に `SKIPPED: input_mode=short_read` を書き、
`core_snp_phylo` が `core_snp_result.json` に **`status: "skipped"`** を書いて正常終了する
(`stage2_core_snp.smk:228`)。ところが API 側の完了判定は
`ResultParser.MODULE_CHECK_MAP["core_snp"] = "core_snp/core_snp_result.json"` の
**ファイル存在だけ**を見ており、`core_snp` は `_OPTIONAL_MODULE_FILES`
(= 完了後に JSON の `status` を読んで `skipped` を確定するリスト) に**入っていない**。
結果、UI の SNP Phylogeny ブランチが緑チェックの「完了」になる。

**#28 の「検査不能を陰性として通す」の UI 版**であり、Illumina が常用になると
「Illumina 検体でも系統解析は走っている」と誤読させる。

- [ ] `_OPTIONAL_MODULE_FILES` に `"core_snp": "core_snp/core_snp_result.json"` を追加する
      (`checkm2` / `bakta` 等と同じ扱い)。
- [ ] `job.core_snp_status` の初期化 (`snakemake_runner.py:1249`) が `long_read` 限定である件と
      合わせて直す。Phase 4 で short_read が実際に走るようになる前に、
      **「走っていない」ことが正しく見える状態**にしておくこと。

### 次に取る実測値 (アーカイブ完了後)

- `assembly/short_read/trimmed_reads_stats.txt` と `fastp.json` → トリム後の総塩基・リード数 → **推定被覆**
- `quast/report.tsv` → N50 / contig 数 / total length (Phase 3-1 の閾値根拠)
- `molecule/molecule_classification.json` → chromosome / plasmid / unclassified の内訳 (Phase 3-2)
- `plasmid_outbreak/registration.json` と `query.json` → 環状フラグ無しで登録 0 件 → **照会も 0 件**になるか (Phase 5 の裏取り)
- ワーカー上の `spades_output/` 残骸サイズ (Phase 1-2 の掃除対象)

### 完走結果 (16:34:20 → 17:00 アーカイブ, 約 26 分)

**アセンブリは実用水準。ONT の双子検体と typing が完全一致した。**

| 指標 | TAS002_Illumina | TAS002_ONT (同一分離株) |
|---|---|---|
| トリム後 | 1,377,348 ペア / **383.5 Mbp** (Q20 95.4% / Q30 90.3%, read 142 bp) → E. coli 5.2 Mb で **約 74×** | — |
| contig 数 | **191** | 8 |
| Total length | 5,214,812 | — |
| N50 | **124,024** | (1 contig 4,917,645 の閉環染色体) |
| CheckM2 | 完全性 **100.0** / 汚染 **0.07** | — |
| 菌種 / MLST | E. coli / `ecoli_achtman_4` **ST11** | E. coli / **ST11** |
| FimTyper | **FimH82** | **FimH82** |
| 血清型 | **O157:H7** | **O157:H7** |
| DEC 病原型 | **STEC/EHEC**, stx **stx2c** / eae+ / HUS リスク「高」, マーカー 20 個 | **完全一致** (同じ 20 マーカー) |
| MOB-suite | primary_cluster **AA345** | primary_cluster **AA345** |

### 計画の修正 (実測で軽くなった / 重くなった論点)

- **QUAST の閾値 (Phase 3-1) は急ぎではない。** 現行の ONT 較正閾値
  (N50 < 10 kb / contigs > 500 で WARN) に対し、実測は N50 124 kb / 191 contig で
  **そのまま PASS** した。良質な Illumina では現行閾値で問題ない。
  低品質データ向けの調整は残すが優先度を下げる。
- **molecule 判定 (Phase 3-2) の劣化も想定より軽い。** 環状性の証拠がゼロでも
  status=PASS / warnings なし、`genome_size_ratio 0.972`、内訳は
  **染色体 150 contig (4,999,415 bp) / プラスミド 4 contig (55,423 bp) /
  判定不能 37 contig (159,974 bp = 全体の 3.2%)**。断片化で判定不能が急増する懸念は外れた。
- **`spades_output/` は NAS まで運ばれている (Phase 1-2 の優先度上昇)。**
  実測 **84 MB** が NAS にアーカイブされ、検体全体 203 MB の **41%** を占める
  (ONT の同検体は 125 MB)。中身は `K21/K33/K55/`, `tmp/`, `before_rr.fasta`,
  `assembly_graph.fastg`, `scaffolds.fasta` 等。**スクラッチだけの問題ではなく NAS に恒久的に残る。**
  ただし `assembly_graph_with_scaffolds.gfa` (5.4 MB) は**残す価値がある** (GfaGraph ビューア)。
- **SPAdes の `cov_` は k-mer 被覆であって read 被覆ではない。** 実測で
  read 被覆 74× に対しヘッダは `cov_42.4` (K55 換算 ≒ 74 × (139−55+1)/139)。
  molecule 判定の `chromosome_depth` も 42.4 と出ている。
  **低被覆 contig フィルタの閾値を「read 被覆」の感覚で置くと 2 倍近く外す。**
- `input/contigs.fasta` は NAS 上で **dangling symlink** (ワーカーのスクラッチを指す)。
  #17 のとおり既知で、ダウンロード API は `assembly/short_read/contigs.fasta` に
  フォールバックする。**ONT と同じ挙動なので新規の問題ではない。**

### 決定的な実測: プラスミド照会が無言で消える (Phase 5 の裏取り完了)

**同一分離株の ONT 版と Illumina 版で、アウトブレイク照会の結果が正反対になった。**

| | TAS002_ONT | TAS002_Illumina |
|---|---|---|
| MOB-recon の primary_cluster | AA345 | **AA345 (同一)** |
| `registration.json` | `num_registered: 1` (`TAS002_ONT__AA345`) | `num_registered: 0` / **`num_skipped: 0`** |
| `query.json` | `num_plasmids: 1` / **`num_with_matches: 1`** / `db_matches: 160 件` / `trigger_layer_b: true` | `num_plasmids: 0` / `num_with_matches: 0` / **`trigger_layer_b: false`** |

Illumina 側は **同じプラスミド (AA345) を検出していて、その AA345 が DB に 160 件ある**のに、
`require_circular` で登録されず → 登録 uid が無い → 照会が 1 件も走らず →
**「マッチ無し」として正常終了**した。しかも `num_skipped: 0` なので
**「プラスミドはあったが登録を見送った」という痕跡すら残らない**。

#28 の無言の偽陰性そのもので、**アウトブレイク検知を取りこぼす方向に壊れる**。
Phase 5 の実装 (照会のみ経路 + `registered: false` の明示) は必須と確定した。

なお PlasmidFinder はレプリコン 0 件だが **ONT 側も 0 件**なので、
これは検出失敗ではなくこの株の性質 (AA345 の rep_type は MOB-typer 由来)。

### この検体で確定した Phase 4 の較正材料

`TAS002_Illumina` と `TAS002_ONT` は **同一分離株 / 同一 ST11 / 同一 FimH82** =
cgSNP 群 `Ecoli/11_H82` に入るべきペア。Phase 4 実装後、
**この 2 検体のペアワイズ SNP 距離がクロスプラットフォーム較正値そのものになる**
(理想は 0 付近。膨らむならその分が ONT の系統的エラー由来)。

---

## 10. 実装記録 (2026-08-19)

決定 1〜4 を反映して実装した。**ONT 既存経路の挙動は変えていない** (回帰確認は下記)。

### 10-1. プラスミド: read-only 照会 (Phase 5) — 最優先

- `register_plasmids_to_db._read_contig_report()` が `(登録対象, 見送り)` の 2 値を返すようにし、
  見送り理由 (`non_circular` / `variant_segment` / `known_vector`) を付ける。
  `registration.json` に `withheld_clusters` / `num_withheld` を追加。
  **登録 0 件で早期 return する経路でも必ず書く** (従来はここで痕跡が消えていた)。
- `check_plasmid_outbreak.py` は登録 uid に加えて **`non_circular` で見送ったクラスタも照会**する。
  `known_vector` / `variant_segment` は「プラスミドとして扱わない」判断そのものなので照会もしない。
  `query.json` に `num_registered` / `num_read_only` / `query_mode` / `read_only_matches`、
  各エントリに `registered` / `withheld_reasons` を追加。
- **`trigger_layer_b` は登録済みのマッチだけで決める。** Layer B.1 は DB 内 FASTA を母集団に
  走るので、DB に居ないプラスミドで起動しても当の検体がクラスタに入らない。
- UI (`PlasmidProfileSection`) と HTML エクスポートに「DB 未登録・照会のみ」を明示。
- 両スクリプトの `main()` に `if "snakemake" in globals():` ガードを追加 (#24)。

**実データ検証**: `TAS002_Illumina` は登録 0 件 → **AA345 で 184 件マッチ / `read_only_matches=true`**
(修正前は 0 件)。`TAS002_ONT` は `num_plasmids=1 / with_matches=1 / trigger_layer_b=true` で
**修正前と同一** (件数が 160→183 に増えているのは 8/16 以降 DB が育ったため。
構造上の差分は `registered` キーの追加のみ)。

### 10-2. cgSNP の「完了」誤表示

`core_snp_phylo` は skip / insufficient / failed でも `core_snp_result.json` を書いて exit 0 するのに、
API はファイルの実在だけで `completed` にしていた。

- `_OPTIONAL_MODULE_FILES` に `core_snp` を追加 (checkm2 等と同じ「status を読む」扱い)。
- `_poll_sample_module_status` が結果 JSON の `status` を読んで
  `skipped` / `failed` / `completed` を出し分ける (`_read_core_snp_status`)。
  読み出しは **`sftp_*` ではなく既存接続への `exec_command`** — SFTP 経路は失敗時に
  接続を張り直すことがあり、同関数の docstring どおり監視ストリームを巻き添えにしうる。
- `core_snp_status` の pending 初期化を `long_read` 限定から `_CORE_SNP_MODES`
  (long_read / short_read / hybrid) に拡張。

### 10-3. SPAdes ルールの実用化 (Phase 1)

- **メモリ上限**: `-m` を明示。config `assembly.short_read.memory_gb: 0` は
  「ワーカー RAM × `mem_fraction_percent`(80) ÷ 同時サンプル数」で自動算出する。
  同時サンプル数はオーケストレータが `--config spades_mem_divisor=` で渡す
  (`core_snp_phylo_jobs` の頭割りと同じ仕組み)。honban 216 GB → 86 GB、
  kibanb/tugrip 61 GB → 24 GB になる。
  **`[ ... ] && VAR=x` を裸で書かないこと** — テストが偽のとき文全体が非ゼロを返して
  `set -e` でルールごと落ちる (実装中に踏んだ)。
- **EXIT trap で後片付け**: `trimmed_R*.fq` と `spades_output/` を成功・失敗どちらでも消す。
  `spades.log` だけは親ディレクトリへ退避する。
- **GFA を保存**: `assembly_graph_with_scaffolds.gfa` を
  `assembly/short_read/assembly_graph.gfa.gz` として残す。
  `results.py` の assembly-graph-gfa エンドポイントは既に `("long_read","short_read")` を
  走査しているので **API 改修は不要**で、既存の GfaGraph ビューアがそのまま使える。
- **低被覆 contig フィルタ**: `workflow/scripts/filter_spades_contigs.py` (新規)。
  SPAdes は `Coverage cutoff is turned OFF` で一切フィルタしないため、コンタミ contig が
  AMR 偽陽性になる。既定 `min_contig_cov: 2.0` は shovill の `--mincov 2` と同基準。
  **`cov_` は k-mer 被覆で read 被覆ではない** (実測 read 74x → `cov_42.4`) 点を
  スクリプトの docstring と config コメントに明記した。
  全 contig が除外されたら空 FASTA を流さず **exit 1 で落とす**。
  実測 TAS002_Illumina で `seqkit seq -m 500` の出力と **バイト一致** (191 contig)。
- **中間ファイル掃除**: `_sweep_intermediates_cmd` に short_read を追加。
  モックツリーで検証済み — `spades_output/` (K21/tmp/before_rr/scaffolds/fastg) を消し、
  `assembly_graph_with_scaffolds.gfa` / `spades.log` / `params.txt` を親へ退避、
  `contigs.fasta` / `assembly_graph.gfa.gz` / `fastp.json` は保持、
  long_read の挙動は不変、パスにスペースがあっても壊れない。
- **hybrid の明示**: ルールのログに「長鎖リードは使用しません (SPAdes 単独)」を残す。

### 10-4. cgSNP の Illumina 対応 (Phase 4)

- `run_core_snp_map.py` に `--short-reads-r1/-r2` 経路を追加。
  ONT の Phase 1-4 (fastplong → DeChat → wgsim) を `run_fastp_paired()` 1 つに置き換える。
  ダウンサンプルは **R1/R2 を同一シード (`seqkit sample -s 42`) で引いてペアを保つ**。
- マッピングは `platform="illumina"` で **`bwa mem` (ペアのまま)**。
  ONT は `bwa bwasw` のまま — 既存 BAM DB が全て bwasw 由来で、差し替えると
  同一 ST 群の BAM 再構築と再検証が要る (#23)。
- `metadata.json` / `mapping_info.json` / `core_snp_result.json` に **`platform` を記録**。
  **platform キーの無い旧登録は ONT** と読む。
- `run_core_snp_phylo.py` が `sample_platforms` / `platform_counts` / `mixed_platforms` を
  結果に載せ、混在時は stderr にも出す。
- UI: `CoreSnpSection` に混在警告、`CoreSnpDbBrowser` の群一覧に「混在: ONT n / Illumina n」。
- `stage2_core_snp.smk` のモードゲートを `long_read` 限定から
  `long_read | short_read | hybrid` に。assembly_complete はリードが無いので従来どおり SKIPPED。

### 10-5. リード QC (Phase 2)

UI に「short-read のリード QC は未対応 (今後 fastp 連携予定)」と出ていた箇所を実装した。

- `per_sample_report.py` が `assembly/short_read/fastp.json` を **params 渡し**で読み
  (circularity.json と同じ理由。DAG を変えない = ONT 検体に影響しない)、
  `read_qc` セクションを作る。
- **推定被覆 = トリム後総塩基 ÷ 期待ゲノムサイズ**。ゲノムサイズはトップレベル
  `genome_size_map` (単一の真実源) を引く。`min_depth_warn` (既定 30) 未満は WARN。
- **fastp.json が無いモードは `status="not_applicable"`** で返し、0x とは書かない (#28)。
- UI (`SampleDetail`) と HTML エクスポートの両方に表示。

**実データ検証** (TAS002_Illumina): 推定被覆 **73.8×** / Q20 95.1% / Q30 89.5% /
重複率 1.3% / インサートサイズ peak 219 bp / status=PASS。
ONT 検体は `not_applicable` になることも確認。

### 10-6. 検証方法と限界

- Python 全ファイル `py_compile` 通過、frontend `tsc --noEmit` エラー 0。
- Snakemake の `shell:` ブロックは **Python の str.format で実レンダリングしてから
  `bash -n`** にかけ、`{}` の取りこぼし (#26 の罠) と構文エラーが無いことを確認した。
- プラスミド read-only / withheld 判定・contig フィルタ・read QC・sweep コマンドは
  **NAS 上の実データ (TAS002_Illumina / TAS002_ONT) とモックツリーで実行して確認**した。
- **未検証 (実機での走行が要る)**: SPAdes ルール全体の再実行 (`-m` / EXIT trap / GFA 保存)、
  Illumina cgSNP の一連 (fastp → stringMLST → bwa mem → BAM DB → phylo)。
  リポジトリにテスト基盤が無いため、テストファイルは追加せず実データ検証に寄せている。

### 10-7. 次にやること (実機)

1. `TAS002_Illumina` を再解析して SPAdes ルールと read QC を実走行で確認する。
   `spades_output` が NAS に残らないこと、`assembly_graph.gfa.gz` が出ることを見る。
2. **cgSNP を有効にして再解析**し、`Ecoli/11_H82` 群に `TAS002_Illumina` が入ることを確認。
   → **`TAS002_ONT` とのペアワイズ SNP 距離がクロスプラットフォーム較正値**になる。
   理想は 0 付近。膨らんだ分が ONT の系統的エラー由来で、
   [[project_lowcov_snp_artifact_signature]] の C↔G 過剰シグネチャも併せて見る。
   **この値が出るまで、跨ぐペアの距離を同一株判定に使わないこと。**
3. 既存の Illumina 検体は 1 件だけなので backfill ツールは作っていない。
   `TAS002_Illumina` の plasmid_outbreak は #28.3 の手法で当該ルールだけ再実行できる。

---

## 11. 実機検証結果 (2026-08-20, job `20260820_072755_62f80083`)

修正後の `TAS002_Illumina` を再解析。**全 5 項目が設計どおり動作した。**

### 11-1. クロスプラットフォーム較正値 = **0 SNP**

```
TAS002_Illumina × TAS002_ONT = 0 SNP   (コアゲノム 4,302,461 bp)
次に近い株 TAS223_ONT        = 18 SNP
集団中央値                   = 460 SNP  (n=167)
```

同一分離株の ONT 版と Illumina 版が **4.3 Mb のコアゲノム全域で 1 塩基も違わなかった**。
さらに両者の距離行列の行は他の全株に対しても完全に一致する
(18 / 62 / 91 / 100 / 100 / 101 / 101 … 同一)。

**決定 1 (ONT と Illumina を同じ群に同居させる) の前提が実測で裏付けられた。**
プラットフォーム間の系統的エラーはこの条件下で距離に寄与しない。
次に近い株が 18 SNP 離れているので、同一株判定の余裕も十分ある。

**限界**: n=1 ペア。DeChat 補正済み ONT R10 を十分な被覆で読んだ場合の値であり、
低被覆 ONT 検体でも 0 である保証はない。ペアが増えたら再確認すること。

### 11-2. その他の検証結果

| 項目 | 結果 |
|---|---|
| cgSNP | `status=completed` / `n_comparison=168` / コアゲノム **79.74%** (閾値 0.6 に余裕) / `mixed_platforms: true` / `platform_counts: {ont: 167, illumina: 1}` |
| BAM DB | `bam_db/Ecoli/11_H82/TAS002_Illumina.bam` (157.5 MB) に `"platform": "illumina"` 記録。参照ゲノムは ONT 版と同一 |
| SPAdes 掃除 | `spades_output/` 消滅。**検体サイズ 203 MB → 126 MB** (ONT 版 125 MB とほぼ同等) |
| GFA 保存 | `assembly_graph.gfa.gz` 1.6 MB (既存 GfaGraph ビューアがそのまま使える) |
| contig フィルタ | 1,141 → 191 contig。長さで 950 本除外、**被覆で 0 本** (`min_cov 2.0` は良質検体では発火しない = 意図どおり) |
| リード QC | 推定被覆 **73.8×** / Q20 95.1% / Q30 89.5% / 重複率 1.3% / インサート peak 219 bp / status=PASS |
| プラスミド照会 | `query_mode: read_only` / `num_read_only: 1` / **AA345 が 184 件マッチ** (修正前は 0 件) / `trigger_layer_b: false` (設計どおり) / `withheld_clusters` に rep_type `IncFIA,IncFIB` と 4 contig を記録 |

### 11-3. 判明した課題: phylo が 168 株で 4 時間 50 分かかる

所要時間の内訳 (ジョブ全体 5 時間 18 分):
- レポート生成まで **28 分** (前回 26 分とほぼ同じ = アセンブリ〜アノテーションは短鎖リードでも変わらない)
- **`core_snp_phylo` だけで 4 時間 50 分** (07:56 → 12:46)

原因は `core_snp.max_strains: 200` で、`Ecoli/11_H82` 群の **168 株がまるごと比較集団**に入るため。
#23 の実測 12.6 分は 22〜28 株のときの値で、株数が増えると
mpileup (168 BAM を全位置で読む)・ClonalFrameML・RAxML (`-f a -N 1000`) が
いずれも株数に対して強く効く。**Illumina 対応とは無関係のスケーリング問題。**

### 11-4. 併せて判明: kaoki_stec の cgSNP は 250/259 が failed のまま

NAS 上の全 `core_snp_result.json` を集計した結果:
`failed 250 / completed 1 / insufficient 5 / skipped 3`。
`TAS002_ONT` も `core_snp_phylo failed (exit 1)` で、
[[project_cgsnp_phylo_nameerror_st]] の既知障害 (`localize_bams` の未定義 `st` による
NameError、1 行修正済み・再実行未) が残っている状態。**今回の変更とは無関係。**
修正後に再実行されたのは `TAS209_ONT` (8/19, n=100, コア 82.18%) の 1 件のみ。

**再実行するなら 11-3 の所要時間を先に決めること** — 250 検体 × 数時間になる。

---

## 12. 多検体投入のための「系統樹あと回し」対応 (2026-08-20)

ONT とペアになる Illumina を多数投入するにあたり、**per-sample では BAM 登録まで、
系統樹は全投入後にまとめて**という運用にするための実装。

### 12-1. 既にあったもの (実装不要だった)

`_run_core_snp_batch` には **phylo-only 経路**が既にある。`_core_snp_mapping_ready` が
`mapping.done` の存在を検知すると `--allowed-rules core_snp_phylo --forcerun core_snp_phylo`
で起動し、**BAM を作り直さずに系統樹だけ**再構築する。Results 画面から
選択サンプルで起動できる (`POST /jobs/core_snp/by-samples`)。
これが無いと NAS 上の `input/contigs.fasta` がリンク切れ (#17) のため
snakemake が flye まで遡って全再解析してしまう、という事故対策として入ったもの。

### 12-2. 追加した「系統樹の保留」

`_build_remote_command` が cgSNP のターゲットを無条件に
`core_snp/core_snp_result.json` にしていたため phylo を止める術が無かった。
`defer_core_snp_phylo` を足し、真なら **`core_snp/mapping_info.json` を終端**にする。

- `JobCreateRequest.defer_core_snp_phylo` (既定 false) → `create_job` → `JobRecord`
- New Job 画面にチェックボックス。**dorado モードでは出さない**
  (下流ジョブは dorado_runner が組み立てるため未対応 = 効かないチェックボックスを見せない)
- **状態表示**: `core_snp_result.json` が出ないので、放置すると UI が永久に
  「待機中」になる。ポーラが `mapping_info.json` を読み、
  `done` → `deferred` / `skipped` → `skipped` を出し分ける。
  `CoreSnpStatus` に `deferred` を追加し、`CoreSnpSection` に
  **「BAM は登録済み・系統樹はまだ作っていない」専用カード**（そこから実行できる）を置いた。
  `PipelineTimeline` では `skipped` 扱い (`pending` に落とすと後処理行が永久に完了しない)。
  `_poll_sample_module_status` の `find` に `mapping_info.json` を追加
  (従来の列挙に含まれておらず、そのままでは検知できなかった)。

### 12-3. ペア単位 cgSNP (`workflow/scripts/pairwise_cgsnp.py`, 新規)

SNP 数は**その run に入れた株の共通部分**で決まるので、群単位とペア単位では数値が違う。
ペアだけならコアゲノムが広くなり鋭敏になる (群 168 株で 79.7% → ペアなら 90% 超の見込み)。

- `bam_db` を走査して sample → {species, group, bam, reference, platform} を作り、
  ペアの BAM を直接 mpileup → VarScan → SNP 数を出す。**bam_db は読むだけ。**
- **参照ゲノムが違うペアは実行せず skip** する。座標系が違うと SNP はでたらめになるが
  エラーにはならない (#26 と同じ「壊れた結果が completed で出る」型)。
- **「bam_db に未登録」を 0 SNP にしない。** 未登録と「差が無い」は別物なので
  `status=skipped` + 理由を残す (#28)。
- 出力 JSON/TSV に `core_genome_bp` / `core_genome_ratio` / `cross_platform` を併記し、
  **群単位の数値と直接比較しない**旨を `note` に入れてある。
- `run_core_snp_phylo.py` の `run_mpileup_consensus` / `extract_snps` / `read_fasta` /
  `reference_length` を import して使う (判定・計算の二重化を避ける)。
- `workflow/scripts/` に置いたので `_sync_pipeline_files` でワーカーへ自動配布される
  (`tools/` は同期対象外)。

### 12-4. 運用手順

1. **投入**: New Job で「Defer cgSNP phylogeny」にチェックして Illumina を投入。
   各検体は BAM 登録 (`core_snp_map`) まで走る。実測 Illumina のマッピングは約 7 分。
2. **全検体の投入後**: `core_snp.max_strains` を**群サイズ以上**に引き上げる
   (現状 200 / `Ecoli/11_H82` は 168。**引き上げないと分離日順で古い株が押し出され、
   ペアの片割れが距離行列から欠ける**)。
3. **群ごとに 1 検体だけ** Results から Core SNP を実行 → phylo-only 経路で
   その群の系統樹と全ペアを含む距離行列が 1 回で得られる。
   (`core_snp_phylo` はサンプル単位なので、群ごとに 1 検体で足りる。
   複数検体を選ぶと同じ木を作り直す。)
4. **ペア単位の確認**: ワーカー上で `pairwise_cgsnp.py` を `--pairs-file` で流す。

現在の群サイズ: `Ecoli/11_H82` 168 株 / `Ecoli/11_H36` 87 株 / 他 3 群は 1 株。
