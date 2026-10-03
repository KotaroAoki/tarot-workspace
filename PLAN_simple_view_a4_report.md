# PLAN: シンプルビュー + A4 1 枚レポート

作成 2026-09-08 / **実装済み (2026-09-08)**

実装で確定した値・踏んだ罠は **CLAUDE.md #53** に集約した。
本ファイルは設計の意図と、なぜその形にしたかの記録として残す。

対象: 検体詳細 (SampleDetail) のシンプル表示モードと、A4 1 枚の PDF レポート。

## 決定事項 (2026-09-08)

| 項目 | 決定 |
|---|---|
| 対象画面 | **検体詳細 (SampleDetail)** のみ。Results 一覧・JobDetail は今回対象外 |
| PDF 生成 | **ブラウザ印刷** (`@page size:A4` の自己完結 HTML → iframe で `print()`)。新規依存ゼロ |
| 内容の重点 | 臨床寄り + 疫学ひとこと |
| **想定読者** | **ICT / 検査部 / 主治医の誰が読んでも通じる**情報量と書き方にする |
| **施設名** | **出す** (マスク切替は作らない)。代わりに取扱注意をフッタに常設 |
| **レイアウト** | **2 つ作る** — ① A4 縦 1 枚 ② **横長ディスプレイでスクロールなしの 1 画面** |
| ResFinder phenotype バグ | **別件に切り出し済み** (§7)。本件はこれを待たない |

---

## 0. 結論

**新しい解析は一切要らない。API の変更も要らない。**
必要な材料は既に `{sample}_report.json` と既存エンドポイントに全部ある。
作るのは「判定 (何を警告と呼ぶか) を 1 箇所に集めた層」と、
その上に載る**画面レイアウト**と**印刷レイアウト**だけ。

最大の設計上の争点は見た目ではなく **「非専門家向けに情報を減らすと、
"検査できていない" が "陰性" に化ける」**こと (CLAUDE.md #28 / #40 と同型)。
シンプルビューはこの事故が最も起きやすい画面なので、
**「判定できなかった項目」ブロックを常設**し、空のときも「該当なし」と
明示的に書く設計にする。

---

## 1. 全体構成 (3 層)

```
lib/sampleBrief.ts             ← 判定と文言の単一の真実源 (純関数, DOM 非依存)
   buildSampleBrief(input): SampleBrief
        │
        └─→ components/SampleBriefView.tsx   ← 部品も React 1 本に統一
                ├ variant="screen" → 画面 (横長 3 カラム, スクロールなし)
                └ variant="print"  → renderToStaticMarkup → A4 縦 2 カラム HTML
```

### 1.1 画面と印刷を **同じ React コンポーネント**で作る

`lib/htmlExport.ts` のような**文字列テンプレートの別実装は書かない。**
印刷 HTML は `renderToStaticMarkup(<SampleBriefView variant="print" …/>)` で
組み立て、CSS 文字列 (`lib/briefStyles.ts`) を画面と印刷の両方が使う。

- `react-dom/server.browser` はサブパスなので **新規依存にはならない**
  (`react-dom` は既にある)。バンドル増は数十 KB。
- レイアウトの差 (横 3 カラム / 縦 2 カラム) は **CSS の
  `grid-template-areas` を `data-variant` で切り替える**だけにする。
  ブロックの中身・順序判定・文言は共通。
- これで「画面には警告が出るのに PDF には出ない」という食い違いが
  構造的に起きなくなる (CLAUDE.md #19 の molecule 判定二重化、
  #42 の図の色の二重化と同じ轍を踏まない)。
- **フォールバック**: Vite のバンドルで `react-dom/server.browser` が
  問題を起こす場合のみ、印刷側を文字列テンプレートに落とす。
  そのときも**文言と判定は `sampleBrief.ts` から取る**こと。

既存の `lib/htmlExport.ts` (詳細 HTML 出力) は**置き換えない**。
あれは「全部載せ」の版で用途が違う。
`isCarbapenemase` / `buildCargoGenes` / `buildPlasmidMap` /
`integronColors` / `epiColors` など既存の共有部品はそのまま使う (再実装しない)。

### 1.2 `SampleBrief` の形 (案)

```ts
export interface SampleBrief {
  identity: {
    displayName: string        // エイリアス適用後
    internalId: string         // **必ず併記する** (CLAUDE.md #18)
    isolationDate: string | null
    facility: string | null    // **出す** (決定事項)
    region: string | null
    analysisDate: string | null
    pipelineVersion: string | null
    partial: boolean           // 解析途中の部分レポートか
  }
  overall: 'PASS' | 'WARN' | 'FAIL' | 'UNKNOWN'

  /** 上部の警告バナー。severity 降順・最大 4 件。overflow は件数を出す。 */
  findings: BriefFinding[]     // {severity, title, plain, detail, source}

  taxonomy: {
    species: string | null
    confidence: string | null
    /** #49.2: 'ok' | 'no_reference' | 'unavailable' を区別して文言を変える */
    speciesStatus: string
    speciesStatusDetail: string | null   // 'no_hits' | 'below_threshold'
    nearestRelative: {name: string; ani: number | null} | null
    mlstScheme: string | null
    st: string | null
    stResolution: string | null          // #32: 'deduplicated' なら注記必須
    serotype: string | null              // Salmonella / E. coli / Klebsiella
    pathotype: string | null             // DEC
  }

  resistance: {
    /** 薬剤クラス → 検出遺伝子。クラスは正規化済み。 */
    classes: Array<{ cls: string; clsJa: string; genes: string[]; carbapenemase: boolean }>
    carbapenemases: string[]             // 最上位で赤く出す
    esbl: string[]
    pointMutations: string[]
    /** ResFinder の gene.phenotype 由来の薬剤名 (推定であって AST ではない) */
    predictedDrugs: string[]
    status: 'ok' | 'partial' | 'unavailable'
    unavailableModules: string[]
  }

  plasmid: {
    numPlasmids: number | null
    replicons: string[]
    pmlst: Array<{scheme: string; type: string | null}>
    carbapenemaseOnPlasmid: string[]     // 可動性の有無が読み方を変える
    integronCassetteAmr: string[]        // #46: カセット上の耐性遺伝子
    status: 'ok' | 'unavailable'
  }

  epi: {
    coreSnp: {
      status: string                     // completed / insufficient / skipped / failed
      group: string | null               // "Ecoli / 11_H82"
      nComparison: number | null
      nearest: Array<{sample: string; snps: number}>   // 上位 3
      note: string | null                // 混在プラットフォーム等
    }
    plasmidDb: { numPlasmids: number | null; numWithMatches: number | null;
                 status: 'ok' | 'not_run' | 'unavailable' }
  }

  qc: {
    tiles: Array<{label: string; value: string; level: 'ok'|'warn'|'bad'|'unknown'}>
    issues: string[]
  }

  /** **常設ブロック。** 空でも消さず「該当なし」と書く。 */
  notAssessed: Array<{ item: string; reason: string }>

  /** 上限で切った項目は件数を必ず残す (#21 の Bakta 100 件切りの教訓) */
  truncated: Array<{ item: string; shown: number; total: number }>
}
```

### 1.3 入力

`buildSampleBrief` は既に取得済みのものだけを受ける。**新規 API は無し。**

| 材料 | 取得元 | SampleDetail での現状 |
|---|---|---|
| `report` | `fetchSampleReport` / `fetchLiveSampleReport` | 取得済み |
| `coreSnp` | `fetchCoreSnpResult` | 取得済み |
| `modules` (available_modules) | `fetchSampleModules` | 取得済み |
| `sampleMeta` (分離日/地域/施設) | `fetchSampleMetadata` | 取得済み |
| `mobSuite` | `fetchSampleModule(s,'mob_suite')` | PlasmidProfileSection が取得 → 引き上げ |
| `plasmidOutbreak` | `fetchSampleModule(s,'plasmid_outbreak_query')` | 同上 |

Results の `downloadHtml()` が既に同じ 7 本を並列取得しているので
([Results.tsx:705](tarot-analyzer/frontend/src/pages/Results.tsx:705))、
将来 Results から一括出力するときもそのまま流用できる。

---

## 2. 書き方 — 誰が読んでも通じるようにする

読者は ICT・検査部・主治医のいずれか。**専門用語を消すのではなく、
専門表記を残したまま 1 行の意味を添える**方針にする
(用語を消すと検査部・ICT が原典と突き合わせられなくなる)。

### 2.1 3 層で書く

```
① 見出し      平易な日本語        「薬剤耐性」「近縁株」「プラスミド」
② 値          専門表記のまま       blaIMP-1 / ST11 / IncHI2 / 0 SNP
③ 意味        値の直下に 1 行      「カルバペネム系を分解する酵素。
                                    院内感染対策の対象になる型」
```

### 2.2 語彙の規則

- **断定しない。** 「〜に耐性」ではなく「**〜耐性遺伝子を保有**」「検出されました」。
- **「感受性」と書かない。** 検出されなかったクラスは
  「耐性遺伝子は**検出されませんでした**」。感受性の担保にはならない。
- **数値には必ず解釈の目安を添える。**
  例: `0 SNP` →「同一由来とみなせる近さ (20 SNP 以内が伝播を疑う一般的な目安)」
  例: `完全性 99.2%` →「ゲノムがどれだけ揃っているか。95% 以上が目安」
- **「不明」と「該当なし」と「検査できていない」を書き分ける** (§4)。
- 用語辞書 (`GLOSSARY`) は `sampleBrief.ts` に定数で持ち、画面と PDF で共有する。

### 2.3 「遺伝子型からの推定」の扱い

見出しは「**遺伝子型からの推定**」。直下に**常に**(折りたたまず)

> 感受性試験 (AST) の結果ではありません。治療方針の判断には AST を使ってください。

を出す。主治医が読む前提なので、この一文は画面・PDF とも省略不可とする。

---

## 3. レイアウト A — 横長ディスプレイ 1 画面 (スクロールなし)

### 3.1 要件

- **既定 1440×900 でスクロール 0**。最低保証 **1280×720**。
- 1920×1080 では余白を増やして文字を大きくする (詰めない)。

### 3.2 構成 (3 カラム)

```
┌ ヘッダ: 検体名 (内部ID) / 分離日 / 施設 / 地域 / 解析日 / 総合判定 ──────┐
├ 所見バナー (最大 4)  ■カルバペネマーゼ ■病原型 ■アウトブレイク ■QC ───┤
├────────────┬───────────────┬───────────────┤
│ 菌種・型別       │ **薬剤耐性** (主役)  │ プラスミド          │
│ QC タイル 7 枚    │ クラス別チップ      │ 疫学 (cgSNP / DB)   │
│              │ 点変異 / 推定薬剤    │ **判定できなかった項目** │
├────────────┴───────────────┴───────────────┤
│ 注意書き / ツール版 / 各ブロックの「詳細を見る →」                    │
└──────────────────────────────────────────┘
```

### 3.3 スクロールなしをどう担保するか

- ルートを `height: calc(100dvh - <アプリヘッダ>)` + `overflow: hidden`、
  内部は CSS Grid。フォントは `clamp()` で 11px〜14px にスケール。
- **CSS の `overflow: hidden` で内容を隠すのは禁止。**
  それは「黙って消える」= #28 と同型。
  **表示件数の上限はデータ側 (`buildSampleBrief` の定数) で決め、
  超過分は必ず「他 N 件 →」と件数付きで出す。**
- 実測で 1280×720 に収まらないことが分かった項目は、
  上限を下げるか右カラムのブロック順を変えて対応する
  (文字を縮めて押し込まない)。

### 3.4 切り替え

- 見出し右に **「シンプル / 詳細」トグル**。
- 状態は `?view=simple` (URL) + `localStorage`。URL に出すのは**そのまま人に送れる**ため。
- **詳細ビューは一切削らない。** シンプルは追加レイヤであって置き換えではない。
- 各ブロックに「詳細を見る →」を置き、詳細ビューの該当カードへアンカー移動する
  (`#amr` `#plasmid` `#cgsnp` …)。行き止まりを作らない。

---

## 4. レイアウト B — A4 縦 1 枚

### 4.1 生成方法 (依存ゼロ)

```
@page { size: A4; margin: 10mm; }
html { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
.sheet { width: 190mm; min-height: 277mm; page-break-after: always; }
```

- 「印刷 / PDF 保存」→ **非表示 iframe に `srcdoc` で流し込み
  `iframe.contentWindow.print()`**。`window.open` はポップアップブロックに
  当たるので使わない。
- 併せて **「HTML で保存」** も出す。iframe 印刷は Safari で不安定なことが
  あるので逃げ道を必ず残す。保存は既存の
  [`downloadHtml`](tarot-analyzer/frontend/src/lib/plasmidStructureExport.ts:148)
  を使う (`<a>` を文書に挿入 + revoke 遅延。CLAUDE.md #42 の
  「2 つめが 1 つめを上書きする」罠を再発させないため、独自実装は書かない)。
- ブラウザ印刷なので**ヘッダ/フッタ (URL・日付) は利用者側で切る**必要がある。
  ボタンの下に一行で案内する。

### 4.2 面付け (210×297mm, 余白 10mm → 190×277mm)

| # | ブロック | 高さ目安 | 内容 |
|---|---|---|---|
| 1 | ヘッダ | 16mm | 検体表示名 **+ 内部 ID**、分離日 / **施設** / 地域、解析日、総合判定 |
| 2 | 所見バナー | 24mm | 最大 4 件。赤 = CRITICAL / 橙 = WARNING / 青 = INFO |
| 3 | 左段 | 150mm | 菌種・型別 → 薬剤耐性 (クラス別、カルバペネマーゼは最上段で赤) |
| 4 | 右段 | 150mm | プラスミド → 疫学 (cgSNP 上位 3 + プラスミド DB 一致) → QC タイル 7 |
| 5 | 判定できなかった項目 | 40mm | **常設**。取得失敗・未実施・対象外を書き分ける |
| 6 | フッタ | 12mm | 注意書き、**取扱注意**、pipeline 版、出力日時、内部 ID の説明 |

**溢れの扱い**: 各リストに上限 (耐性クラス 8 / 遺伝子 6 per クラス / 近縁株 3 /
レプリコン 8) を置き、超過は必ず **「他 N 件 (詳細レポートを参照)」**。
**黙って切らない。** 実測で 1 枚に収まらない検体が出たら 2 ページ目に流す
(内容を削るより増ページを選ぶ)。

### 4.3 施設名を出す以上、必要なこと

施設名 + 分離日 + 菌種が揃うと症例が特定されうる (CLAUDE.md #43)。
マスク切替は作らない決定なので、代わりに:

- フッタに常設: **「本レポートには施設名・分離日が含まれます。院外への共有前に
  取扱いをご確認ください。」**
- ファイル名にも施設は入れない (`tarot_brief_{表示名}_{timestamp}.html`)。
- 部分レポート (`partial=true`) のときは**「解析途中 — 暫定」の帯**を
  ヘッダに必ず入れる (完成品として出回るのを防ぐ)。

### 4.4 載せない / 載せる

**載せる**: 菌種 + 信頼度、ST、血清型・病原型、耐性クラスと主要遺伝子、
カルバペネマーゼ / ESBL、点変異、プラスミド本数とレプリコン、
カルバペネマーゼの染色体/プラスミド別、cgSNP 最近縁 3 件、
プラスミド DB 一致件数、QC 7 指標、判定不能項目。

**載せない** (詳細ビュー / 詳細 HTML に任せる): ゲノムマップ、
プラスミド構造比較、系統樹、インテグロン地図、遺伝子ごとの %ID/%Cov、
Bakta/PlasAnn の全 feature、距離行列。
**図は 1 枚も入れない** — A4 1 枚に図を入れると必ず表が削られ、
削られるのは決まって「判定できなかった項目」になる。

---

## 5. 非専門家向けだからこそ必要な安全策

| 事故 | 対策 |
|---|---|
| **検査不能 → 陰性に見える** (#28 / #40) | `notAssessed` を常設ブロックにする。モジュール status が `FAIL` / `unavailable` / `not_configured` のものを列挙し理由を書き分ける。空なら「該当なし」と書く (ブロックごと消さない) |
| **表示名が内部 ID を隠す** (#18) | ヘッダと PDF フッタで**必ず内部 ID を併記** |
| **菌種 Unknown の理由が分からない** (#49.2) | `no_reference` (再解析しても変わらない) と `unavailable` (再実行で直りうる) を文言で分ける。`status_detail` の `no_hits` / `below_threshold` も固定文にしない |
| **ST が mlst の生値と区別できない** (#32) | `st_resolution: 'deduplicated'` のときは「重複除去で確定した ST」と併記 |
| **cgSNP の「完了」が skip を隠す** (#37.2) | `core_snp_result.json` の status を読み、`skipped` / `insufficient` / `failed` を「近縁株なし」と書かない |
| **プラスミド DB 未登録が「一致なし」に見える** (#37.1) | `withheld_clusters` があれば「DB 未登録・照会のみ」と明示 |
| **部分レポートが完成品に見える** | `partial=true` は帯 + PDF フッタで明示 |
| **CSS で溢れを隠す** | 上限はデータ側で決め、超過は件数を出す (§3.3) |

---

## 6. 実装ステップ

### Phase 1 — 判定層 (バックエンド変更なし)
1. `frontend/src/lib/sampleBrief.ts` を新規作成。
   `buildSampleBrief()`、用語辞書 `GLOSSARY`、severity 定義、表示上限定数。

### Phase 2 — 部品と画面レイアウト
2. `frontend/src/lib/briefStyles.ts` — 画面と印刷で共有する CSS 文字列。
   `data-variant="screen" | "print"` で `grid-template-areas` を切り替える。
3. `frontend/src/components/SampleBriefView.tsx` — props は
   `{ brief: SampleBrief; variant: 'screen' | 'print' }` のみ。
   fetch もアラート判定もしない。
4. `SampleDetail.tsx` に `?view=simple` トグルを追加。
   **フックは早期 return より前に置く** (#44 / #46.3 で 2 回踏んでいる)。
   `mob_suite` / `plasmid_outbreak_query` はシンプルビュー用に
   `useQuery` を足す (PlasmidProfileSection からの引き上げは差分が大きいので後回し)。

### Phase 3 — A4 出力
5. `frontend/src/lib/briefReport.ts` —
   `renderToStaticMarkup` + `briefStyles` + `@page` で自己完結 HTML を組む。
6. `frontend/src/lib/printHtml.ts` — iframe 印刷ヘルパ (srcdoc + print)。
7. SampleDetail に「A4 レポート (印刷 / PDF)」「HTML 保存」ボタン。

### 対象外 (今回やらない)
- Results 一覧 / JobDetail のシンプル化 — `sampleBrief.ts` ができれば安く作れるので、
  必要になった時点で別途。
- ResFinder `phenotype_predictions` の修正 — **別件に切り出し済み** (§7)。
  本件は `acquired_genes[].phenotype` の薬剤名リストで進める。

---

## 7. 検証方法

**目視で終わらせない** (CLAUDE.md #45.6)。

1. **純関数を NAS 全検体に当てる** — `vite build --ssr` で一時エントリを束ねて
   node から `buildSampleBrief` を全 1,100+ 検体の実 `*_report.json` に適用し、
   - 例外 0 件
   - `notAssessed` が常に配列で返る (undefined にならない)
   - 「モジュール status=FAIL なのに耐性 0 件を陰性として出していないか」の走査
   - **各ブロックの行数分布**を集計し、A4 1 枚 / 1 画面に収まる検体の割合を実測する
     (収まらない検体の特徴を先に知る)
2. **レンダー例外** — `react-dom/server` で `SampleBriefView` を合成データ
   (メタデータ皆無 / 取得失敗 / 部分レポート / 全モジュール FAIL) に当てる。
   TDZ とフック順は tsc を通るので**これでしか捕まらない** (#44)。
3. **実ブラウザで実測** — `frontend/__harness.html` に実検体 4 種
   (通常 / カルバペネマーゼ保有 / DEC 陽性 / 解析途中) を props 直叩き。
   ログイン不要で回せる (#45.6)。確認するのは:
   - **1280×720 / 1440×900 / 1920×1080 の 3 解像度で `scrollHeight <= clientHeight`**
   - print preview のページ数 (A4 1 枚に収まるか) と色落ち・余白
   - 確認後にハーネスは削除
4. **既存画面の非退行** — 詳細ビューの DOM が変わっていないこと
   (シンプルは追加であって改変ではない)。

---

## 8. 別件に切り出したもの

**`amr_gene_profile.phenotype_predictions` が全検体で壊れている。**

`workflow/scripts/parse_resfinder.py:92-105` が `pheno_table.txt` を
`csv.DictReader` にそのまま渡しているが、実ファイルは**先頭 16 行がコメント**で
本物のヘッダはその後にある。結果、コメント行がヘッダとして採用され、
実測 `10671` では **106 行すべてがコメント文字列**になっていた。

```json
{"# ResFinder phenotype results.": "# Sample: contigs.fasta"}
```

- **今のところ被害は無い。** このフィールドを読む画面もエクスポートも 1 つも無い。
  Results の `resfinder_phenotypes` 列は別経路 (`acquired_genes[].phenotype`) で正常。
- ただし #28 の「パースはしているが誰も見ていないので壊れていても気づかない」構造そのもの。
- **ResFinder の再実行は不要** — `pheno_table*.txt` は NAS に全検体分残っている
  (実測 kaoki_stec 525 検体に 1,042 ファイル)。パース修正 + backfill で直る。
- 直れば「抗菌薬ごとの Resistant / No resistance + Match (0-3)」が使えるようになり、
  A4 の「遺伝子型からの推定」の粒度が上がる。
  **本件はこれを待たず `acquired_genes[].phenotype` で進める。**

---

## 9. 残る未決事項

1. **アプリヘッダを含めた「1 画面」の実高さ** — `page-header--sticky` の高さ次第で
   使える縦幅が変わる。実測してから上限定数を決める。
2. **所見バナーの上限 4 件で足りるか** — 実データでの `findings` 件数分布を
   §7-1 で測ってから確定する。
3. **QC タイル 7 枚をシンプルビューでも 7 枚出すか** — 非専門家には
   「完全性 / 汚染 / 被覆」の 3 枚 + 「その他は詳細へ」で足りる可能性がある。
   実測後に判断。


---

## 10. 実装結果 (2026-09-08)

### 入ったもの

| ファイル | 役割 |
|---|---|
| `frontend/src/lib/sampleBrief.ts` (新規) | **判定と文言の単一の真実源**。純関数 |
| `frontend/src/lib/briefStyles.ts` (新規) | 画面と A4 で共有する CSS |
| `frontend/src/components/SampleBriefView.tsx` (新規) | 描画。`variant` で置き場所だけ変える |
| `frontend/src/lib/briefReport.ts` (新規) | A4 自己完結 HTML (`renderToStaticMarkup`) |
| `frontend/src/lib/printHtml.ts` (新規) | 非表示 iframe + `srcdoc` で印刷 |
| `frontend/src/pages/SampleDetail.tsx` | `?view=simple` トグル / ボタン / 要約用の fetch |
| `frontend/src/index.css` | トグルと `.app-main` の横幅解除、遺伝子名の表記 |
| `frontend/src/lib/geneName.ts` (新規) | 遺伝子名の表記 (イタリック / 下付き) の単一の真実源 |
| `frontend/src/components/GeneName.tsx` (新規) | その描画 (HTML / SVG)。詳細は CLAUDE.md #54 |

**API / workflow の変更はゼロ。** 新規依存もゼロ。

### 実測 (NAS 全 1,111 検体 + 合成 3 件)

| 項目 | 結果 |
|---|---|
| `buildSampleBrief` の例外 | **0 件** |
| A4 HTML の生成失敗 | **0 件** |
| 「検査不能を陰性として出す」検出 | **0 件** |
| A4 1 枚に収まらない検体 | **0 件** (最大 274.0mm / 上限 277mm。遺伝子名の下付きで +3.6mm) |
| 1280×720 でスクロールする検体 | **0 件** |
| 1440×900 / 1920×1080 | 同じく **0 件** |
| A4 HTML のサイズ | 14〜18 KB / 検体 (自己完結) |
| 初期バンドルへの影響 | **±0** (レポート生成は動的 import に分離) |

### 実測で決めた値

- 画面のフォント: `clamp(12.5px, 0.95vw, 15px)`。
  1280×720 で **12.5px は溢れ 0 件 / 13px は 1,114 件中 7 件が溢れる**。
- A4 は薬剤耐性ブロックを**全幅**に置く。半幅だと行が折り返して倍の高さになり、
  最も重い検体が 277.6mm (紙をはみ出す) → **270.4mm** に収まった。

### 未実施 (意図的)

- Results 一覧 / JobDetail のシンプル化 — 対象外の決定どおり。
  `sampleBrief.ts` があるので必要になれば安く作れる。
- ResFinder `phenotype_predictions` の修正 — 別件に切り出し済み (§8)。
  現状は `acquired_genes[].phenotype` で代替しており、実用上は足りている。
