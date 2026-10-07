# ハイブリッドアセンブリ (長鎖 + 短鎖) の計画

**状態 (2026-10-07)**: **段階 0 (比較試験) 完了、段階 1 を実装済み (未コミット・未デプロイ)**。
本番の Snakemake ルールで 11514 を honban のスクラッチで通しで検証中。実装の要点と実測は CLAUDE.md #78。
次は proteus の R9 36 検体をハイブリッドで解析し直して置き換える (9.1 章)。

**位置づけ (2026-10-07 ユーザー決定)**: **研究用のオプション。** 主な用途は、
**古い ONT R9.4.1 のリード**を Illumina と組み合わせて、なんとかアセンブリに使うこと。
日常の解析 (R10.4.1 + Dorado sup v5 の長鎖単独、Illumina 単独) は今のまま変えない。

## 決定事項

| 項目 | 決定 |
|---|---|
| 用途 | 研究用オプション。古い R9.4.1 + Illumina が主対象 |
| アセンブラ | **Unicycler** (短鎖主導)。理由は 0 章 |
| 2 つのリードが同じ株でないとき | **検体を失敗扱いにし、DB に登録しない** (どちらが正しい株か判断できないため) |
| 長鎖の被覆が低いとき | 止めずに続け、被覆を警告として出す (Unicycler は長鎖が少なくても組める) |
| 短鎖にしかない小型プラスミド | アセンブリには入れ、「短鎖のみ」と明示する。**プラスミド DB には環状でも登録しない** |
| 比較試験のデータ | kaoki_stec の ONT/Illumina ペアを使ってよい (スクラッチで実行し DB には書かない) |
| 有効にする方法 | **New Job で「ハイブリッド (研究用)」を選んだときだけ**。そのジョブに長鎖と短鎖の両方を入れる |
| R9 の評価データ | ユーザー手元のデータ。**キットは RBK004** (R9.4.1)、**同じ DNA から Illumina も読んである**。ベースコーラーの版は不明 (FASTQ のヘッダと品質の分布から推定する。Unicycler は medaka を使わないので版が分からなくても進められる) |

---

## 0. 結論

### アセンブラは Unicycler にする (前回の「長鎖主導」案から変更)

前回の案 (Flye で組んで短鎖で研磨) は **R10.4.1 + sup を前提にした推奨**だった。
対象が古い R9.4.1 なら Unicycler の方が合う。

| | Unicycler (短鎖主導) | 長鎖主導 (Flye → 研磨) |
|---|---|---|
| 塩基の正確さ | **配列は短鎖 (SPAdes) のグラフから**。長鎖は反復の橋渡しに使うだけなので、R9 の誤り (リード単位で 5〜10%) の影響を受けにくい | 骨格の塩基が長鎖由来。R9 では研磨前の誤りが R10 より桁違いに多く、medaka と短鎖研磨の両方が要る |
| 開発者の想定 | README (2026 更新):「**低被覆・低精度の長鎖**を使うように設計した」(初期の Nanopore 向け)。「長鎖の被覆が低いときに使う」 | R10 世代の推奨 |
| 長鎖の被覆が低いとき | 橋渡しが減るだけで、短鎖のアセンブリより悪くはならない | 断片化する |
| 既存パイプラインへの影響 | **今の hybrid の分岐 (SPAdes ルール) の中で置き換えるだけ。** 日常の長鎖経路に触らない | 日常の Flye ルールに R9 用の分岐が要る (下記) |
| 実行時間 | 長い (SPAdes の複数 k + 橋渡し + Racon。要実測、数十分〜1 時間超の見込み) | 短い |

**長鎖主導を R9 で使うには、日常の Flye ルールを 3 か所変える必要がある**:
1. 前処理の fastplong は**既定で品質フィルタが有効** (Q15 未満の塩基が 40% を超えるリードを捨てる。
   honban で `fastplong --help` を確認)。R9 のリードは大半がこれに引っかかる。
2. Flye の入力モードは `--nano-hq` (誤り 5% 未満の前提)。R9 は `--nano-raw`。
3. medaka は R9 用のモデルが要り、そのモデルは**古いデータのベースコーラーと版に合わせる**必要がある
   (古いデータでは分からないことが多い)。

研究用のオプションのために日常の経路の中心に分岐を足すのは割に合わない。
R10 + Illumina がハイブリッドで投入された場合も Unicycler で組むことになるが、研究用なので許容する
(R10 sup は長鎖単独で十分正確なので、日常はそちらを使う)。

### 研磨: medaka は使わない。Unicycler の後に Polypolish だけをかける (比較試験で決定)

- Unicycler の配列は短鎖由来なので、**基本的に研磨は要らない**。
- 例外は、短鎖のグラフに経路が無く**長鎖の配列そのもので橋渡しした区間**。Unicycler は
  ここを長鎖で Racon 研磨するが、R9 では誤りが残りうる。
- そこで比較試験で、Unicycler の出力に **Polypolish (careful) + Pypolca (careful)** を 1 回かけて
  変更件数を測る。ほぼ 0 なら入れない。変更が出るなら最後の工程として入れ、
  件数を必ず記録する。
- medaka は使わない (Unicycler には不要。R9 のモデルを合わせられない問題もそのまま残る)。

---

## 1. 現状

- `classify_input` は長鎖と短鎖の両方があると `mode=hybrid` にするが、**中身は SPAdes 単独で
  長鎖リードは捨てている** (#37.4)。cgSNP は短鎖を使う。
- **NAS の全検体 (約 1,600) に hybrid は 0 件。** 既存結果の移行は不要。
- ワーカー (honban・tugrip で確認): SPAdes 4.2.0 / dnaapler 1.3.0 / blastn は py39 にある。
  **Unicycler・Racon・minimap2・Polypolish・Pypolca・Filtlong は無い。** bwa と samtools は
  `core_snp_env` にある。Plassembler 1.8.2 が py39 に入っているが Unicycler が無いので動かない。
  **py39 には足さない** (全損の前例)。

## 2. 実測 — kaoki_stec の ONT (R10.4.1) / Illumina ペア 259 組

R10 のデータなので R9 の性能評価には使えないが、**入力一致の確認の較正**と
**組み込みの試験**に使える。

### 2.1 同じ菌株でない組がある (3 / 259)

| 組 | ONT | Illumina |
|---|---|---|
| TAS182 | E. coli ST196 | E. coli ST11 |
| TAS216 | E. coli ST3018 | E. coli ST11 |
| TAS255 | **Salmonella** (ST313) | E. coli ST11 |

公開データでもこの割合で起きる。**入力一致の確認は必須** (4.3)。

### 2.2 遺伝子単位の比較 (一致した 256 組、AMRFinderPlus の共通遺伝子 9,403 件)

| | 件数 | 中身 |
|---|---:|---|
| 両方で同じ結果 | 7,838 | |
| Illumina だけ切れている | 574 | espF / tccP / stxA2 / iss — 反復で短鎖のアセンブリが切れる |
| ONT だけ切れている・止まっている | 24 | ehxA が複数の組で同じ 77.86% で切れる = 決まった位置で起きる読み誤り |
| 両方全長で ONT の一致率が低い | 34 | |
| 両方全長で Illumina の一致率が低い | 73 | 未確認 |

**Unicycler の評価の目安になる**: 反復で切れていた 574 件が長鎖の橋渡しでどれだけ全長になるか。
ONT 側の誤り 58 件は、配列が短鎖由来なら最初から出ないはず。

### 2.3 小型プラスミド (10 kb 未満) で Illumina にだけ在るもの

ONT のアセンブリに無いものが 31 件。ONT のリードまで探すと、TAS049 AA667 (3,361 bp) は
**668 本のリードに在るのに Flye が組めていない**。TAS213 AB595・TAS055 AA576 は
**リードに 0 本** (2 つのリードが別の DNA から読まれている)。
後者が「短鎖のみ」のプラスミド (決定事項の 3 行目) の実例になる。

### 2.4 被覆

長鎖 509 検体の 9.8% が 20x 未満。kaoki_stec の Illumina は中央値 63x、最小 20.8x。

---

## 3. 方針の全体像

```
短鎖 ─ 複数ランの結合 (#60) → fastp ──────┐
                                          ├→ Unicycler (--no_rotate) → contig 名の正規化 → dnaapler
長鎖 ─ 長さだけでふるう (品質では捨てない) ─┘        → [仕上げ研磨: 要否は比較試験で]
                                                     → [入力一致の確認 + contig ごとの長鎖の裏付け]
                                                     → assembly/short_read/contigs.fasta
cgSNP ─ 短鎖 (今と同じ bwa mem)。入力一致の確認を待ってから BAM を登録
```

## 4. 実装の要点

### 4.1 有効にする方法 — ジョブ単位で明示的に選ぶ (決定済み)

**New Job で「ハイブリッド (研究用)」を選んだときだけ** Unicycler を使う。
`config_overrides` に `hybrid_assembly=true` を足す (利用者が指定できるキーの許可リスト
`USER_CONFIG_OVERRIDE_KEYS` に追加。#62)。選ばなければ今と同じ (SPAdes 単独) で、
「長鎖リードは使っていません」という表示を足す。
→ 日常の解析にはこのフラグを付けない限り一切影響しない。

### 4.1.1 入力ファイルの判定 — 古い Guppy の出力名で壊れる (要修正)

`classify_input` はファイル名だけで長鎖と短鎖を分けている (サブフォルダは見ない)。
古い Guppy の出力をそのまま置くと、次の 2 つで壊れる:

1. **Guppy のチャンク番号が Illumina のペアに見える。** Guppy / MinKNOW は 1 つのランを
   `..._pass_barcode01_<runid>_0.fastq.gz`, `_1.fastq.gz`, `_2.fastq.gz` … (古い版は
   `fastq_runid_<runid>_0.fastq`, `_1`, `_2` …) と分けて書く。Illumina の
   `sample_1.fastq.gz` / `sample_2.fastq.gz` 用の規則がこの `_1` と `_2` に当たり、
   - Illumina が `_R1_001` の名前なら、**チャンク `_1` と `_2` が長鎖から黙って外れる**
     (`unpaired_reads` に記録はされる)。
   - Illumina が `_1` / `_2` の名前なら、**チャンク `_1` と `_2` が Illumina の 2 組目のペアとして
     短鎖に混ざる** (#60 の結合で SPAdes / Unicycler に入る)。
   - 長鎖だけを置いた場合は、**チャンク同士が Illumina のペアと判定され hybrid になる**。
2. **長鎖を名前の手掛かりで見分けている。** 短鎖が同居しているとき、長鎖は `barcode` /
   `rbk` / `fastq_runid_` / `nanopore` / `ont_` のどれかを名前に含まないと採られない
   (`sample_ont.fastq.gz` は `ont_` に当たらないので採られない)。

**直し方**:
- `fastq_runid_` / `_pass_` / `_fail_` / `barcode\d+` を含むファイルは、`_1` / `_2` の規則で
  Illumina のペアにしない (長鎖だけの投入でも効くので、日常の経路の安全にもなる)。
- `_fail_` を含むファイル (Guppy の品質基準に落ちたリード) は使わず、記録だけ残す。
- `hybrid_assembly=true` のジョブでは、Illumina の名前でない残りのファイルは**名前の手掛かり
  無しで**長鎖として採る (利用者が両方を入れると明示しているので推測が要らない)。
- 結果画面に「長鎖として使ったファイル / 短鎖として使ったファイル / 使わなかったファイル」を出す。

**直すまでの回避策**: 検体フォルダごとに、Guppy の pass のチャンクを 1 つにまとめて
(gzip は `cat` でそのまま連結できる) `<検体名>_nanopore.fastq.gz` のように `nanopore` を含む名前にし、
Illumina は `<検体名>_R1_001.fastq.gz` / `_R2_001.fastq.gz` にする。
今の判定で実際に試した結果 (2026-10-07): `11529_nanopore.fastq.gz` / `11529_nanopore_r941.fastq.gz` /
`11529_rbk004.fastq.gz` / `11529_barcode05.fastq.gz` / `11529_ont_r941.fastq.gz` は長鎖になる。
`11529.fastq.gz` / `11529_ont.fastq.gz` / `11529_R9.fastq.gz` は長鎖にならない。
**`11529_nanopore_1.fastq.gz` も長鎖にならない** (末尾の `_1` で Illumina と判定される)。

### 4.2 置き場所と DAG — 今の hybrid の分岐をそのまま使う

- `get_input_fasta` は既に hybrid → `assembly/short_read/contigs.fasta` を返している。
  **SPAdes ルールのシェルの中で、hybrid かつフラグありなら SPAdes の代わりに Unicycler を呼ぶ。**
  出力ファイル名は同じなので、他のモードの DAG も、`assembly/short_read/` を読む
  API・backfill・画面もそのまま動く。
- 長鎖リードは、**hybrid かつフラグありのときだけ** SPAdes ルールの input に入る関数で渡す
  (それ以外は空 = 今と同じ DAG。`_core_snp_subtype_inputs` と同じ形)。
- GFA は `assembly/short_read/assembly_graph.gfa.gz` に置く (グラフの画面はそのまま使える)。
- 何で組んだかは `assembly/short_read/hybrid/hybrid_report.json` に書く (アセンブラと版、
  長鎖・短鎖の被覆、Unicycler の橋渡しの数、環状に閉じた分子の数、研磨の結果、入力一致の確認)。
  画面の「どのアセンブラか」(`lib/assemblySource.ts`) はこれを見て「Unicycler (hybrid)」と出す。

### 4.3 入力一致の確認

- R9 の長鎖は 1 本ずつの誤りが多いので、**一致率の平均では別株を見分けられない**
  (同じ菌種の別 ST は ANI 99% 前後で、R9 の誤り 5〜10% に埋もれる)。
- そこで、長鎖を Unicycler の contig に並べ (minimap2)、**十分な深さがある位置で長鎖の多数決が
  contig と食い違う置換 (挿入・欠失は数えない)** を数える。ランダムな読み誤りは多数決で消え、
  別株なら数千〜数万の置換が出る。R9 の系統的な読み誤り (メチル化モチーフ等) で数十は出うる。
- **閾値は自分で決めない。** kaoki_stec の一致 256 組と不一致 3 組 (R10)、さらに R9 のデータで
  分布を取ってから決める (#38)。別属の組 (TAS255) は長鎖がほとんど並ばないことでも分かる。
- 外れたら検体を失敗扱いにする (決定事項)。**cgSNP の BAM 登録とプラスミド DB の登録より前に**
  判定する。今の `core_snp_map` は `input_class.json` にしか依存しないので、hybrid のときだけ
  確認の結果を input に足す。

### 4.4 contig ごとの長鎖の裏付け (短鎖のみのプラスミド)

- 同じ minimap2 の結果から、contig ごとに「長鎖が何本・長さの何割を覆っているか」を出す。
- 裏付けの無い contig は `short_read_only` と記録し、**プラスミド DB には登録しない**
  (`register_plasmids_to_db` の見送り理由に `short_read_only` を足し、`withheld_contigs` に残す。
  照会だけは行う #37.1)。画面とレポートに「短鎖のみ」と出す。
- 閾値は比較試験で決める。なお対象の **RBK004 (ラピッドキット) は小型プラスミドが少なくならない**
  (ライゲーションキットでは 20 kb 未満のプラスミドが平均で約 4 分の 1 に減るが、ラピッドでは減らない。
  Wick 2021)。本物の小型プラスミドなら長鎖の裏付けは取れるはず。

### 4.5 contig 名と起点

- Unicycler のヘッダは `>1 length=... depth=1.00x circular=true` の形。数字だけの名前は
  他の検体の命名とずれるので、`contig_N_length:L_circular` の形に揃える。
  **`depth=` は染色体を 1 とした相対値なので `cov:` には入れない** (単位の違う値を同じ欄に
  入れない。#37 の k-mer 被覆と同じ教訓)。相対値は `hybrid_report.json` に別に持つ。
- 起点合わせは Unicycler 自身の回転を止め (`--no_rotate`)、**長鎖の経路と同じ dnaapler** で行う。
  起点の規則が検体によって違うと、プラスミドの構造比較で開始点が揃わない (#42.4)。
- 短鎖のアセンブリから来るので多量体の縮約 (#49) は通さない。
- #69 のグラフ延長は SPAdes の GFA (k-mer の重なりあり) が前提なので、Unicycler の検体では
  動かさない (先に形式を確かめ、合わなければ対象外と記録する)。

### 4.6 長鎖の前処理

- **品質では捨てない** (fastplong の既定フィルタは R9 のリードの大半を捨てる)。
  長さ (例: 1 kb 未満を捨てる) だけでふるう。
- 長鎖が非常に多い (例: 100x 超) ときは間引く。Unicycler は全長鎖を並べるので時間が延びる。
  要否と目標は比較試験で決める。

### 4.7 画面・レポート

- New Job に「ハイブリッド (研究用)」の選択。結果画面とレポートに「研究用のハイブリッド
  アセンブリ (Unicycler)」と明記。`read_qc` に長鎖と短鎖の両方。
- 失敗 (入力不一致) は赤で「短鎖と長鎖が同じ菌株に見えません」と、置換の件数を出す。
- HTML 出力と A4 レポートのアセンブリ表記。日英の文言。

### 4.8 環境

新しい conda env (`unicycler_env`): unicycler 0.5.x / spades / racon / minimap2 / samtools
(+ 仕上げ研磨を入れるなら polypolish / pypolca / bwa)。**SPAdes 4.x との組み合わせが動くかは
導入時に確かめる** (Unicycler は SPAdes 3.14 以上を要求)。py39 には入れない。
3 台のワーカーすべてに作る。

## 5. 段階

| 段階 | 内容 |
|---|---|
| 0. 比較試験 | 7 章。本番の結果・DB には触らない |
| 1. 組み込み | 4 章のすべて |
| 2. (必要なら) 仕上げ研磨 | 比較試験で変更が出た場合のみ |

## 6. 検証項目 (段階 1 の完了条件)

- フラグを付けないジョブ・長鎖だけ・短鎖だけ・アセンブリ投入の検体で、**DAG と出力が今と同じ**。
- 不一致の 3 組が失敗扱いになり、一致の組が誤って弾かれない。
- 2.2 の「Illumina だけ切れている」遺伝子が長鎖の橋渡しで全長になる割合。
- MLST / pMLST / FimH / 血清型が短鎖単独の結果と一致 (塩基は短鎖由来なので一致するはず)。
- 環状に閉じた染色体・プラスミドの数 (SPAdes 単独と比べて増える)。
- 「短鎖のみ」の contig がプラスミド DB に入らないこと。
- 実行時間とメモリ (tugrip は 61 GB)。

## 7. 比較試験の進め方 (段階 0)

- **R9 のデータ = ユーザー手元の RBK004 + 同じ DNA の Illumina。** アプリからは投入しない
  (今の hybrid = SPAdes 単独で走り、グループの cgSNP の BAM DB に登録されるため)。
  NAS の `tmp/hybrid_r9_bench/` に**手元の形のまま**置いてもらい (整理はこちらで行う)、
  Guppy の出力名・チャンクの数・FASTQ ヘッダ (ベースコールのモデル名が入っていれば版が分かる)・
  品質の分布を先に確かめる。4.1.1 の判定の試験にもそのまま使う。
- 正解のゲノムが無いので、同じ株の比較は次で行う: (1) 短鎖単独 (SPAdes) との塩基の一致
  (Unicycler の配列は短鎖由来なので一致するはず)、(2) 環状に閉じた染色体・プラスミドの数、
  (3) 長鎖を並べ戻したときの食い違い。必要なら公開データ (Polypolish の論文のデータセットに
  R9.4.1 + Illumina + 正解のゲノムがある見込み。要確認) を足す。
- **R10 のペア** (kaoki_stec): 不一致 3 組 + 一致の組から約 20 組 (2.2 で差があった組と TAS049 を含む)。
  入力一致の確認の較正と、組み込みの試験に使う。
- **実行**: ワーカーのスクラッチで、DB のパスを 2 つ目の `--configfile` でスクラッチへ向けて
  本物のルールを回す (#57 の形)。NAS の results・plasmid DB・BAM DB には書かない。
- **比べるもの**: SPAdes 単独 (今の hybrid) / Unicycler / Unicycler + 仕上げ研磨 /
  (正解のゲノムがあればそれとの差)。

## 8. 決めてほしいこと

1. ~~有効にする方法~~ → New Job で明示的に選んだときだけ (2026-10-07 決定)。
2. ~~比較試験に使う R9 のデータ~~ → 手元の RBK004 + 同じ DNA の Illumina (2026-10-07 決定)。
3. **比較試験の準備の了承** — (a) データを NAS の `tmp/hybrid_r9_bench/` に置いてもらう、
   (b) ワーカー 1 台 (honban) に比較試験用の conda env (`unicycler_env`) を作る。
   py39 には触らない。env はそのまま段階 1 で使う。

## 8.1 比較試験の結果 (2026-10-07)

- **11514 (R9.4.1 RBK004 Guppy 5 hac + MiSeq)**: Unicycler 45 分で 3 本とも環状
  (4,016,264 / 38,901 / 16,436 bp)。以前の手作業の Unicycler (bold + Pilon) と同じ構成。
  Flye `--nano-raw` は 6 contig (重複 55 kb) で、研磨後も Unicycler と 119 置換 + 31 挿入欠失の差。
- **研磨は Polypolish だけ**: 11514 (Guppy 5 hac) は 0 か所だが、11529 (2019 年の古い Guppy) は
  318 か所を書き換え、314 か所が独立に組んだ SPAdes と一致 (= 本物の修正)。Pypolca は書き換えの
  半分以上が SPAdes と食い違うか判断不能で使わない。
- **入力一致の確認**は「長鎖の多数決 (90%) と食い違う置換を含む 10 kb 窓の割合」で判定
  (同じ株 1〜5% / 別株 73〜100%)。kaoki_stec の 12 組のうち **7 組が別株** (MLST が同じ ST11 の 4 組を含む)。
- 11529 (2019 年の古い Guppy, 平均 Q 約 10, 短鎖 約 390x) は Unicycler の SPAdes の段階だけで 2 時間超
  → 本実装では短鎖・長鎖とも 500 Mb を上限に間引く。

## 9.1 proteus の R9 36 検体の置き換え (ユーザー依頼, 2026-10-07)

`accounts/proteus/nanopore_R9/<検体>/` (Guppy の出力そのまま, 31 GB) と
`accounts/proteus/illumina/<検体>/` (MiSeq) を組み合わせる。
1. 本実装をコミット → TAROT-ORCH に反映 (サブモジュールを先に push。reference_submodule_push)。
2. 現在の 36 検体の results を `accounts/proteus/_backup/<日付>_pre_hybrid/` に退避 (1.1 GB)。
3. `accounts/proteus/hybrid_inputs/<検体>/` に相対シンボリックリンクで両方のリードを並べる。
   2019 年の 2 検体 (11529 / 13314) はヘッダにモデルが無いので、リンク名を
   `<検体>_nanopore_r941.fastq.gz` にして R9.4.1 を伝える (実体の名前は変えない)。
4. New Job (パス指定) で `hybrid_inputs` を指定し「ハイブリッド (研究用)」と「Defer cgSNP phylo」を選ぶ。
5. 終わったら入力一致の確認の値を 36 検体で一覧にし、`mismatch` があれば中身を確かめる。
6. プラスミド関連性をグループ全体で回し直す (#42.1)。cgSNP の系統樹も Results から回す。
7. 入力の種類の backfill (`backfill_input_summary.py --accounts-root ... --apply`) を全アカウントに当てる。

## 9. この計画の外

- **R9 の長鎖だけの検体**は今の長鎖経路では正しく扱えない (4.6 の品質フィルタ、Flye の入力モード、
  medaka のモデル)。長鎖だけで投入する予定があるなら別に計画する。
- 長鎖だけの R10 検体の研磨 (medaka v2 + bacterial モデル)。2.2 の 58 件で評価できる。
- Dorado で読んだ検体に Illumina を後から足す経路。

## 参考

- Unicycler README (2026 更新) — https://github.com/rrwick/Unicycler
- Bouras et al. 2024 "How low can you go?" (R10.4.1 の短鎖研磨。medaka 1.11.3 + sup v4.3 は正味マイナス) — https://pmc.ncbi.nlm.nih.gov/articles/PMC11261834/
- Bouras et al. 2024 "Hybracter" — https://www.ncbi.nlm.nih.gov/pmc/articles/PMC11165638/
- Wick & Holt 2022 "Polypolish" のデータセット — https://bridges.monash.edu/articles/dataset/Polypolish_paper_dataset/16727680
- Wick et al. 2021 "Recovery of small plasmid sequences via Oxford Nanopore sequencing" (ラピッドキットは小型プラスミドが減らない) — https://pmc.ncbi.nlm.nih.gov/articles/PMC8549360
