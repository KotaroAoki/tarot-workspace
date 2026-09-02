# PLAN: クラス 1 インテグロンの検出と描画

作成 2026-09-02 / **層 A・層 B ともに実装済み** (骨格マーカー blastn +
IntegronFinder 2.0.6 + カード + Genome Map + HTML 出力)。
**ワーカー 3 台の env 作成・実機検証・NAS 全 823 検体への backfill まで完了
(2026-09-02)。** クラス 1 陽性 205 検体 / attC 761 / カセットに
carbapenemase 132 検体。実施結果と踏んだ罠は CLAUDE.md #46.2。
実装で確定した閾値・実測値・踏んだ罠は **CLAUDE.md #46 (層 A) と #46.1 (層 B)** に集約した。

---

## 0. 結論

**可能。ただし現状のどのモジュールもインテグロンを検出していない**ので、新しい検出層が要る。
描画側は既存の Genome Map / MGE カードの資産をほぼそのまま使える。

推奨は **2 層構成**:

| 層 | 何をするか | 新規ツール |
|---|---|---|
| **A. 骨格検出 (必須)** | intI1 / 5'-CS / 3'-CS (qacEΔ1–sul1) を blastn で検出し、既存 AMRFinder 座標からカセット列を組む | 不要 (blastn は py39 に既存) |
| **B. attC 検出 (推奨)** | IntegronFinder 2.0.6 で attC サイト・In0 / CALIN・クラス 2/3 まで拾う | `integronfinder_env` (新規 conda env) |

**B なしでも「クラス 1 インテグロンの検出と描画」は成立する** (クラス 1 は 5'-CS/3'-CS が
定義的に効く数少ないクラス)。ただし **attC が無いと「AMR 遺伝子を持たないカセット」
(`orfX` / `ereA` 等) が原理的に見えず、カセット境界も近似**になる。

**決定 (§8): A + B を同時に実装する。** ただし実装順は A → B とし、
**B が使えないワーカー・検体では A だけで `status=partial` に落ちる**構造を保つ
(§2.4)。A の出力スキーマに attC の枠を先に用意しておく。

---

## 1. 実測調査 (2026-09-02, NAS 全 8 アカウント)

### 1.1 現状のモジュールは 1 つもインテグロンを見ていない

| モジュール | 実測 | 結論 |
|---|---|---|
| **MEFinder** | 692 検体 PASS / 28,479 エレメント。type は `insertion sequence` 19,643 / `composite transposon` 4,412 / `mite` 4,204 / `unit transposon` 190 / `ice` 30。**名前 2,053 種のうちインテグロン由来は 0 件** | MEFinder の DB にインテグロンが無い |
| **ABRicate** (vfdb/megares/card/ncbi/resfinder) | 60 検体 16,204 ヒットに `intI` / `integron` が **0 件** | 不可 |
| **AMRFinderPlus** | `intI1` は **0 件** (耐性遺伝子ではないので DB に無い)。ただし 3'-CS の `qacEdelta1` / `sul1` とカセット遺伝子 (`aadA1/2/5/22`, `dfrA1/5/12/14/17/27`, `cmlA1/5`, `estX-3`, `arr`, `catB3`) は**豊富に取れている** | カセット内容の権威として使える |
| **PlasAnn** | `intI1` ("class 1 integron integrase IntI1", 1,014 bp) と `attI` (`AAC_AAD_leader`, 72 bp) を **検出できる**。ただし全 757 ユニット中 **22 検体分のみ** | 部分的にしか当たらない (下記) |
| **Bakta** | on-demand のみ + レポートの `features` が名前順 100 件で切られる (CLAUDE.md #21) | 主データ源にはできない |

### 1.2 PlasAnn では足りない — 実測で 3 分の 1 しか拾えていない

`toho_micro_id` (76 検体) で突き合わせた結果:

- AMRFinder が **qacEΔ1 と sul1 の両方**を持つ = 3'-CS 陽性: **75 / 76 検体**
- PlasAnn が `intI1` を報告: **22 検体**
- 両方: 21 / **3'-CS のみ: 54** / PlasAnn のみ: 1

全アカウント合計では 3'-CS 陽性 **174 検体 / 825 検体 (21%)**
(harada_ndm 11、kaoki_stec 27、kojima 2、toho_micro_id 75、toho_micro_id_bsi 40、
toho_micro_id_temp 14、toho_omori 5、yamaguchi 0)。

**PlasAnn を使えない理由は 3 つ**:
1. **プラスミドユニットしか見ない。** `molecule_classification.json` がある検体で 3'-CS
   マーカーの所在を数えると **プラスミド 61 検体 / 染色体 13 検体** = **クラス 1 陽性検体の
   約 18% は染色体性**で、PlasAnn の視野に入らない。
2. 座標が**プラスミド単位 FASTA 上**で contig 座標ではない (CLAUDE.md #42)。
3. レポート JSON の `features` は「名前付き CDS を名前順に 500 件」で切られる
   (`MAX_NAMED_CDS_PER_UNIT`)。#21 と同型の取りこぼし経路が残っている。

→ **PlasAnn は「補強証拠」としてのみ使う** (intI1 / attI を検出していれば裏づけに載せる)。
判定の材料にはしない。

### 1.3 したがって

**「クラス 1 インテグロン陽性の検体が 174 件あるのに、UI 上はどこにも出ていない」**
のが現状。AMR 遺伝子が可動性のカセットに載っているかどうかは疫学上の主要な所見なので、
足す価値は実データで裏づけられている。

---

## 2. 検出設計

判定は **`workflow/scripts/classify_integron.py` のみが行う** (CLAUDE.md #19 の
二重化事故の再発防止)。frontend も htmlExport も backfill も**この出力を読むだけ**で、
判定式を持たない。

### 2.1 層 A: 骨格検出 (blastn, 新規 env 不要)

新規ルール `workflow/rules/stage1_integron.smk`:

```
rule integron_scan:      # blastn -subject contigs.fasta -query resources/integron/integron_markers.fasta
rule parse_integron:     # classify_integron.py で骨格 + カセット列を確定
```

- **blastn は `-subject` で DB ビルド不要** (`screen_known_vectors.py` /
  `compare_plasmid_structure.py` と同じ idiom)。`blastn` の探索パスは
  `_build_remote_command` の conda prefix 列と同じものを使う
  (**ユーザー名を決め打ちしないこと** — アカウント制ワーカーは mbuser ではない)。
- 参照は `workflow/resources/integron/integron_markers.fasta` に**凍結**する
  (`workflow/resources/paidb/` と同じ前例。`workflow/` は tar で自動同期される)。
  中身と取得元アクセッションを `integron_markers.tsv` に併記し、`build_markers.py` で
  再取得できるようにする (`build_paidb.py` と同形)。想定 ~20 KB。
  - `intI1` (1,014 bp, class 1), `intI2` (Tn7), `intI3` — **クラス判定用**
  - `attI1` (5'-CS 側), `Pc` プロモータ領域
  - 3'-CS: `qacEΔ1`, `sul1`, `orf5`
  - Tn402/tni モジュール (`tniA/B/C/Q`), `IS6100`, `IS26`, `sul3` 型 3'-CS
- 閾値: **自分で決めない** (CLAUDE.md #38)。`identity ≥ 90` / `coverage ≥ 0.8` を
  config に出し、決定前に実データ 174 検体で分布を見て確定する。
- **クラス判定**: intI ヒットのうち最良を採り、intI1 に対して `identity ≥ 95` かつ
  `length ≥ 0.9 × 1014` → class 1。intI2/intI3 が最良なら class 2/3 として
  「クラス 1 ではない」と明示する。短縮 intI1 は `partial_integrase` として残す
  (In0 の一部や欠失型は実在する)。

### 2.2 カセット列の組み立て

1. `intI1` の位置と向きを起点に、下流 (attI1 側) へ `distance_thresh` (既定 4,000 bp、
   IntegronFinder と同値) 以内で連鎖する要素を集める。
2. カセット内容は **既存 AMRFinder / ResFinder の座標をそのまま使う**。
   contigs.fasta は全モジュール共通なので座標は無変換で乗る (#42 で md5 一致を確認済み)。
   - **PlasAnn と Bakta は座標系が違う** — PlasAnn はプラスミド単位 FASTA 上、Bakta は
     `contig_names_restored` フラグが立っている結果のみ使用可 (#22)。
     復元されていない Bakta 結果は材料にしない。
3. 3'-CS (`qacEΔ1`→`sul1`→`orf5`) が揃えば `complete_3cs`、`sul3`/`IS6100` 終端なら
   その旨を記録。3'-CS が無いものも**捨てない** (In4 型など実在する)。
4. **カセット配列シグネチャ**を正規化文字列で出す:
   `intI1|aadB|catB3|blaOXA-10|aadA1|3'-CS`。In 番号 (INTEGRALL) の代わりにこれを
   検体間比較のキーにする (§5)。

### 2.3 層 B: IntegronFinder 2.0.6 (attC / In0 / CALIN)

- bioconda に `integron_finder 2.0.6` があり、依存は hmmer (3.1b2–3.3.2) /
  infernal (1.1.2–1.1.4) / prodigal / biopython / pandas / matplotlib / python ≥3.10。
  **py39 には絶対に入れない** (共有環境全損の前例)。専用 `integronfinder_env` を作る。
- 実行例:
  ```
  integron_finder --local-max --func-annot --promoter-attI \
    --topology-file topology.txt --cpu {threads} --outdir . --gbk --mute sanitized.fasta
  ```
- 出力 `Results_Integron_Finder_<stem>/<stem>.integrons` の列は
  `ID_integron, ID_replicon, element, pos_beg, pos_end, strand, evalue, type_elt,
  annotation, model, type, default, distance_2attC, considered_topology`
  (`type` ∈ `complete` / `In0` / `CALIN`)。**ヘッダは実物で 1 件確認してから
  パーサを確定する** (#42 の教訓)。
- **踏むと分かっている罠 (実装前に必ず対処)**:
  - **複数レプリコンの FASTA は既定で linear 扱いになる** (ドキュメント確認済み)。
    環状 contig で attC が原点を跨ぐと落とすので、**`--topology-file` を必ず渡す**。
    環状かどうかは `molecule/molecule_classification.json` (#19 の単一の真実源) から取る。
    4 kb 未満の contig は IF 側で強制的に linear になる点も出力に残す。
  - **contig 名を IF に生で渡さない。** 我々のヘッダは
    `contig_2_length:6019678_cov:42_circular rotated=True rotated_gene=repA` で、
    `:` と空白を含みファイル名に使えない。**サニタイズした FASTA (`seq_1..N`) を入力にし、
    自分が作った名前対応表で戻す** (#22 の教訓を「出力を推測で突合する」ではなく
    「入力側で権威ある対応表を持つ」形にする)。対応表は結果 JSON に残す。
  - `--local-max` は感度が上がるが cmsearch が重い。**まず 1 検体で実測**して
    config の既定を決める (stage1 の全モジュール合計が 1.8 分 = #23 なので、
    ここだけ数分かかると比率が変わる)。
  - `--keep-tmp` は既定 off。`Results_Integron_Finder_*` と prodigal の `.prt` が
    NAS へアーカイブされる量を実測し、必要なら `_sweep_intermediates_cmd` に足す
    (#37 の `spades_output` 84 MB と同型のリスク)。

### 2.4 「検査不能」を「陰性」にしない (CLAUDE.md #28 / #28.1 / #28.2)

- ルールは `|| true` を使わない。`PIPESTATUS` で終了コードを見て、
  **かつ出力ファイルの実在**で判定する (exit 0 でも空のことがある)。
  失敗時は `INTEGRON_ERROR` マーカーを書き、**ルール自体は exit 0** で下流を巻き込まない。
- **ガードに使うファイル名は実物で確認する** (#28.2 の fimtyper 事故 = 全 E. coli が
  FAIL になった)。blastn 出力 (自分で名前を決める) と IF 出力
  (`<stem>.integrons` / `<stem>.summary`) の両方を実物で確認。
- パーサの status は 4 値:
  - `PASS` … 検査できて陰性 (`num_integrons: 0`) も含む
  - `FAIL` … 検査不能 (ツール失敗 / 出力不在)
  - `partial` … 層 A のみ成功、層 B (attC) が無い
  - `skipped` … config で無効 / アセンブリ無し
- `classify_integron.py` は **`build_result()` 純粋関数**に切り出し
  (Snakemake と backfill の単一の真実源)、`main()` は
  `if "snakemake" in globals():` でガードする (#24)。

---

## 3. 出力スキーマ

`results/{sample}/integron/integron_result.json`:

```jsonc
{
  "module": "integron",
  "status": "PASS",            // PASS | FAIL | partial | skipped
  "engines": {
    "marker_blast": {"status": "ok", "identity_min": 90.0, "coverage_min": 0.8},
    "integron_finder": {"status": "unavailable", "reason": "env not installed",
                        "version": null, "local_max": null}
  },
  "summary": {
    "num_integrons": 2,
    "num_class1": 2,
    "has_class1": true,
    "classes": ["1"],
    "carbapenemase_in_integron": true,   // カセットに carbapenemase があるか
    "cassette_signatures": ["intI1|blaIMP-1|aac(6')-Ib|3'-CS"]
  },
  "integrons": [
    {
      "id": "In_1",
      "class": "1",                      // "1" | "2" | "3" | "unknown"
      "class_evidence": {"intI_identity": 99.8, "intI_coverage": 1.0,
                         "intI_reference": "intI1_Tn21", "three_prime_cs": true},
      "completeness": "complete",        // complete | In0 | CALIN | partial_3cs | unknown
      "contig": "contig_3",              // 復元済みの内部 contig 名
      "start": 41250, "end": 49880, "strand": "+",
      "spans_origin": false,             // 環状 contig で原点を跨いだか
      "molecule": "plasmid",             // molecule_classification.json 由来
      "primary_cluster_id": "AA002",     // MOB クラスタ (プラスミドのとき)
      "rep_type": "IncL/M",
      "integrase": {"gene": "intI1", "start": …, "end": …, "strand": "-",
                    "truncated": false},
      "att_sites": [{"kind": "attI1", "start": …, "end": …, "source": "marker_blast"},
                    {"kind": "attC",  "start": …, "end": …, "evalue": 1e-8,
                     "source": "integron_finder"}],
      "cassettes": [
        {"order": 1, "gene": "blaIMP-1", "start": …, "end": …, "strand": "+",
         "amr_class": "beta-lactam", "identity": 100.0, "coverage": 100.0,
         "source": "amrfinder", "is_carbapenemase": true, "attc_downstream": true}
      ],
      "three_prime_cs": [{"gene": "qacEdelta1", …}, {"gene": "sul1", …}],
      "context": {"tni_module": false, "is6100": true, "flanking_mge": ["IS26"]},
      "signature": "intI1|blaIMP-1|aac(6')-Ib|3'-CS",
      "supporting": {"plasann_intI1": true, "plasann_attI": true}
    }
  ],
  "contig_name_map": {"seq_3": "contig_3"},
  "warnings": []
}
```

レポート側は `_build_integron_section(modules)` を `per_sample_report.py` に追加し、
`report.integrons` に焼き込む。**UI は判定を持たない。**

---

## 4. 描画設計

### 4.1 新カード `IntegronCard.tsx` (主役)

MGE カード (`PlasmidProfileSection` 内) の直後、AMR Gene Profile より上に置く
(診断上の優先度: 「その AMR 遺伝子が可動性か」は AMR の読み方を変える)。

**インテグロン 1 本 = 1 本の横棒**。左から:

```
 [intI1 ◄]  attI1 ▼   ┌ aadA2 ►┐ ᴀ  ┌ dfrA12 ►┐ ᴀ   [ qacEΔ1 ► sul1 ► ]   (IS6100)
 └─ 5'-CS ─┘          └── cassette array ──────┘      └──── 3'-CS ────┘
```

- カセットは AMR class 色 (`classColor` 再利用) の矢印。carbapenemase は赤ハロー
  (Genome Map と同じ様式)。
- attC は**ロリポップ (▼)**。intI1 / attI1 / 3'-CS は専用色で、レーンの左右端に固定。
- **色と形の定義は `frontend/src/lib/integronColors.ts` に集約**する。
  カード・Genome Map・htmlExport の 3 か所で使うので、複製すると
  「同じカセットが図によって違う色」になる (#42 / #45.4 の教訓)。
- 図の下に表: 順序 / 遺伝子 / クラス / %ID / %Cov / 長さ / attC / 由来 (AMRFinder /
  IF / PlasAnn)。**ソートは `lib/tableSort.ts` + `SortHeader` を使う**
  (`Number(null) === 0` を踏まないよう `numOrNaN()` 経由 — #45.4)。
- バッジ: `class 1` / `complete` / `In0` / `CALIN` / 分子 (染色体・プラスミド + rep 型) /
  `carbapenemase 保有`。
- **`status` の書き分けを必ず出す** (#28 / #40): `FAIL` は赤枠で
  「インテグロン陰性ではなく検査できていません」、`partial` は
  「attC 未検出 (IntegronFinder 未実行) のためカセット境界は近似」と明記。
  0 件のときだけ「クラス 1 インテグロンは検出されませんでした」と書く。

### 4.2 Genome Map への統合

`GenomeMap.tsx` は現在 **内側 = AMR / 外側 = MGE** の 2 トラック (#45.3 で下地の帯を
敷いてある)。ここに **3 本目の細いレーン**を AMR と MGE の間に足す。

- インテグロンは**点ではなく区間**なので、ブラケット (円形では細いアーク、線形では
  角括弧付きのバー) で範囲を描き、内部に attC のロリポップを立てる。
- **最も情報量が高いのは「インテグロン内に入る AMR 遺伝子を陰影で示す」こと。**
  該当区間に半透明の放射 / 縦帯を敷き、「この blaIMP-1 はインテグロン内」が
  一目で読めるようにする。帯には `pointer-events: none` を付ける (#45.3)。
- 凡例・中心キー (`内側 AMR / 外側 MGE`) と左ラベルの更新を忘れないこと。
  下地の帯は AMR (寒色) / MGE (暖色) と衝突しない中間色にする。
- **attC は 40–200 bp = 5 Mb contig 上で 0.03 px。** #45.2 のとおり
  **透明な当たり判定層を最前面に重ねる** (最小 10 px / 円形は最小 3.4°)。
  ツールチップの位置は `lib/tooltipPosition.ts` を使う (`d3.pointer(event, body)` は
  `position: fixed` では画面外に飛ぶ — #45.1)。
- MGE type フィルタに `integron` を足す。
  **ついでに直すべき既存バグ**: `canonicalMgeType` は先頭 2 文字で判定するので、
  MEFinder の実際の type 文字列 (`composite transposon` / `unit transposon` / `mite`)
  が全部 `other` に落ちている (`insertion sequence` だけが偶然 `IS` に当たる)。
  `Tn` / `cn` の色は一度も使われていない。

### 4.3 HTML エクスポート

`lib/htmlExport.ts` に `renderIntegrons()` を追加。**図の幾何を書き直さない** —
#42 のとおり「描画済み DOM を複製する」方式が既にあるならそれに寄せ、
無ければ `integronColors.ts` を共有して同じ関数から生成する。
注記として「カセット境界は attC 未検出の場合近似」「検査不能は図に出ない」を必ず添える。

### 4.4 配線 (忘れると無言で壊れる箇所)

| 場所 | 追加内容 |
|---|---|
| `api/services/result_parser.py` | `MODULE_FILES` / `MODULE_CHECK_MAP` に `integron` |
| `api/services/snakemake_runner.py` | rule→module マップ (`integron_scan` / `parse_integron`)、`MODULE_CHECK_MAP`、**`_OPTIONAL_MODULE_FILES`** (status を読ませないと skipped/failed が「完了」の緑チェックになる — #37.2) |
| `frontend/src/components/PipelineTimeline.tsx` | モジュール行 (無いと「処理中なのに Report 完了」になる — timeline gap の前例) |
| `frontend/src/lib/api.ts` | `IntegronResult` 型 |
| フェッチ | **`.catch(() => null)` を書かない** (#40)。既に `GenomeMapSection.tsx:44` と `PlasmidProfileSection.tsx:431` に同じ握り潰しが残っているので、この機会に直す |
| `config/config.yaml` | `integron:` セクション (enabled / conda_env / threads / 閾値 / local_max) |
| `workflow/tests/test_integron.py` | `build_result()` のユニットテスト (`test_dec_alerts.py` と同形) |

**Results 一覧への列追加 (「クラス 1 インテグロン」) は今回やらない。**
`summary_row.py` のキャッシュを触ると 800+ 検体の backfill が必要になる
(project_results_page_load_speedup)。必要になったら別フェーズ。

---

## 5. 検体間比較 (Phase 3, 任意)

カセット配列シグネチャ (`intI1|aadA2|dfrA12|3'-CS`) は **In 番号の代わりに使える
比較キー**で、外部 DB を要らない。

- 同一シグネチャを持つ検体を並べる = 「同じインテグロンが施設内で広がっている」
  の直接証拠。cgSNP 系統樹では見えず、プラスミド距離マップとも独立した軸。
- 置き場所は距離マップ (#41 / #44) のノード軸 (`色分け: インテグロン型`) が自然。
  `sample_metadata` のような新テーブルは不要 — レポート JSON から集約できる。
- **INTEGRALL の In 番号付与は採らない** (外部 DB の可用性に依存し、
  ダウンロード物の保守が必要)。将来やるなら `workflow/resources/integron/` に
  凍結した表を置く形にする。

---

## 6. 既存検体への遡及 (backfill)

825 検体分の再解析は不要。**アセンブリを作り直さずに当該ルールだけ回せる** (#28.3):

```bash
snakemake --snakefile $W/workflow/Snakefile --configfile $W/config/config.yaml \
  --allowed-rules integron_scan parse_integron --config input_dir=$NAS_RESULTS \
  results_dir=$NAS_RESULTS samples=<sample> \
  --cores 4 --rerun-triggers mtime --rerun-incomplete \
  $NAS_RESULTS/<sample>/integron/integron_result.json
```

- **`--allowed-rules` の直後に `--config` を置く** (引数を貪欲に取る)。
- **`classify_input` を走らせないこと** (`input_class.json` を破壊する — #28.3)。
- **`input/contigs.fasta` は NAS 上で dangling symlink になっている** (#17)。
  ルールの input をそのまま使うと backfill が全滅するので、
  `assembly/long_read/contigs.fasta` → `assembly/short_read/…` → `assembly/contigs.fasta`
  の候補順で解決する (`_CONTIG_CANDIDATES` と同じ順序・同じ `-r`/`-s` 判定)。
- レポートは `workflow/scripts/backfill_integron.py` (dry-run 既定) で
  **`integrons` セクションだけ差し替える**。
  **`backfill_sample_reports.py --force` は使わない** (paidb / molecule_classification /
  assembly_circularity / vector_screen / bakta / plasann が消える — #28)。
- 冪等性: 同じ contig に二度当てても壊れない設計 (座標を書き換えない) だが、
  `integron_result.json` の再生成は `contigs.fasta` の size + mtime で判定し、
  許容は 1 秒未満 (#26 の BAM キャッシュと同じ理由)。**±600 秒の余裕**が必要なのは
  新旧比較のときだけ (#28.2)。

---

## 7. フェーズと検証

| Phase | 内容 | 検証 |
|---|---|---|
| **0** | 参照 FASTA の確定 (`resources/integron/`)、閾値の分布確認 | 3'-CS 陽性 174 検体で intI1 の %ID / %Cov 分布を見て閾値を決める (#38: 既定を自分で決めない) |
| **1** | 層 A (blastn) + `classify_integron.py` + JSON スキーマ + テスト | ローカルで NAS の contigs.fasta 数検体に直接当てる (SSH 不要)。**PlasAnn が intI1 を報告している 22 検体は必ず一致すること** |
| **2** | `IntegronCard.tsx` + 配線 + htmlExport | `frontend/__harness.html` で props 直叩き検証 (#45.6)。DOM 実測 (当たり判定 px / ツールチップ座標 / ソート) まで行う |
| **3** | Genome Map 統合 (3 本目のレーン + AMR ハイライト) | 同ハーネス。CVD 検証は色を増やさない方針なので不要だが、下地の帯と既存 2 帯の区別を確認 |
| **4** | 層 B (IntegronFinder env) | 1 検体で実測 (所要時間 / topology-file の効き / `.integrons` のヘッダ)。`--local-max` の有無で attC 数を比較 |
| **5** | backfill = **3'-CS 陽性 174 検体を優先** (dry-run → apply) | 22 検体の PlasAnn 一致 + 174 検体の検出率。**ペア検体 (同一分離株の 2 回シーケンス) でシグネチャが一致すること**が最良の妥当性検証 (#32 / #38 で使った手法) |

**所要見積り**: Phase 1–3 で本体はできる (層 A + 描画)。Phase 4 は
`integronfinder_env` の作成待ち — env 未整備でも Phase 1–3 は先に進められる
(層 A のみで動き、B は `status=partial`)。

---

## 8. 決定事項 (2026-09-02, ユーザー決定)

1. **層 A + 層 B を同時に実装する。** IntegronFinder 用の専用 conda env
   `integronfinder_env` を 3 ワーカーに作る (**py39 には絶対に入れない**)。
   → 着手前に必要なこと: env 作成、1 検体での所要時間実測、`.integrons` ヘッダの実物確認、
   `--topology-file` の効きの確認。**env が未整備なワーカーでは層 A のみで
   `status=partial` に落ちる**設計にすること (#28.1 の「ワーカー間の差分を疑う」——
   PlasmidFinder の Docker イメージ不在が 26 検体の偽陰性になった前例と同型。
   ワーカーによって結果が変わり、再現性が無いように見える形で表面化する)。
2. **全 contig (染色体 + プラスミド) を対象にする。**
   実測でクラス 1 陽性検体の約 18% が染色体性。
3. **backfill は 3'-CS 陽性 174 検体を優先**し、残りは後追い。
   優先対象の抽出は AMRFinder の `qacE*` + `sul1` 同時保有で機械的に選べる
   (§1.2 の集計スクリプトがそのまま使える)。
   **層 B を 825 検体に当てると数十時間規模**なので、全数化は所要時間の実測後に判断。
4. **Results 一覧への列追加は行わない** (`summary_row.py` キャッシュの backfill を
   避ける。§4.4)。

---

## 9. 副産物 (この調査で見つかった既存の不具合)

インテグロン実装とは独立だが、隣接する箇所なので同時に直す候補:

1. **MEFinder が 133 / 825 検体で FAIL** (`KeyError: 'contig_1'`)。
   `--temp-dir` によるキャッシュ隔離を入れる前 (2026-07-18) の検体。
   MGE カードが空のままなので、インテグロンカードを隣に置く前に backfill したい
   (**MEFinder の再実行が必要** — 出力が残っていないため #28.2 のような
   「再実行不要」の救済はできない)。
2. **`canonicalMgeType` が `Tn` / `cn` を一度も返さない** (§4.2)。
   MEFinder の type は `composite transposon` 等の語なので、
   4,602 件が `other` (灰色) に落ちている。
3. **`.catch(() => null)` が 2 箇所残っている**
   (`GenomeMapSection.tsx:44`, `PlasmidProfileSection.tsx:431`)。#40 と同型で、
   取得失敗が「MGE 0 件」として静かに描画される。
