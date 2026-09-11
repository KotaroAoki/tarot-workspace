# 日本語 / 英語 表示切替 — 実装プラン

作成: 2026-09-10 / 方針確定: 2026-09-10 / **Phase 0–4 完了: 2026-09-11**
フロント残件 0 / サーバー由来の文言もコード + パラメータ化済み。
**既存 1,111 検体も再解析なしで英語表示になる** (§Phase 4 の実測を参照)。

---

## 1. 現状の実測

コード上の推測ではなく、実際に数えた値。

### 1.1 フロントエンド

| 項目 | 実測値 |
|---|---|
| 日本語を含むファイル (`.ts`/`.tsx`) | **66 / 68** |
| 日本語を含む行 | 5,431 (うちコメント行 2,862 / **コード上の文字列 ~2,485**) |
| **一意な翻訳対象文字列** | 文字列リテラル 985 + JSX テキストノード 525 = **約 1,510** |
| うち `${}` 補間を含むもの | **283** |
| 引数なしの `toLocaleString()` / `Intl.*` | **87 箇所** (= ブラウザロケール依存で今も不定) |
| 既存の i18n ライブラリ | **無し** (i18next / react-intl / lingui いずれも未導入) |
| 既存の言語設定 | **無し** (`index.html` は `lang="en"`、書き出す HTML は `lang="ja"` 固定) |

多い順 (一意文字列数):

```
177  lib/htmlExport.ts              64  components/IntegronCard.tsx
176  components/PlasmidDistanceMap  52  components/SampleBriefView.tsx
128  pages/SampleDetail.tsx         48  lib/integronColors.ts
113  components/PlasmidProfileSect  46  components/PlasmidStructureChain
106  lib/sampleBrief.ts             46  pages/Admin.tsx
 95  lib/notifiableDiseases.ts      …  (残り約 50 ファイル)
 82  components/CoreSnpSection.tsx
 78  lib/briefBadges.ts
 72  components/PlasmidStructureCompare.tsx
 65  components/MstGraph.tsx
```

### 1.2 描画先は React だけではない (これが設計を決める)

| 出力先 | 実装 | 言語切替の要件 |
|---|---|---|
| 画面 (React 19) | 各コンポーネント | `useSyncExternalStore` で購読 |
| **A4 1 枚レポート** | `briefReport.ts` → `renderToStaticMarkup(SampleBriefView)` | React 外の同期呼び出し |
| **詳細 HTML 書き出し** | `htmlExport.ts` (純粋な文字列組み立て、92 KB) | React 不在 |
| **構造比較図の HTML** | `plasmidStructureExport.ts` (DOM 複製) | 注記文のみ |
| **判定ロジック層** | `sampleBrief.ts` / `briefBadges.ts` / `plasmidMap.ts` / `integronColors.ts` / `notifiableDiseases.ts` / `mstGrouping.ts` | 純関数。React に依存させられない |
| **d3 描画** | GenomeMap / PlasmidDistanceMap / MstGraph / GfaGraph / PhyloTree / PlasmidStructure×3 | **effect の依存に言語が要る** |

→ **翻訳の読み出しは React コンテキストに依存させられない。** これは既存の
`lib/sampleAlias.ts` (CLAUDE.md #18) が解いたのとまったく同じ形の問題で、
同じ解 (モジュールシングルトン + `useSyncExternalStore` + React 外アクセサ) を採る。

### 1.3 サーバーが生成した日本語がレポート JSON に焼き込まれている

NAS の実レポート **120 / 1,111 件**を走査した結果 (出現数):

| JSON パス | 出現 | 例 |
|---|---:|---|
| `molecule_classification.contigs[].evidence[].label` | 17,347 | `MOB-recon が cluster 付きで plasmid と判定` |
| `molecule_classification.contigs[].reason` | 8,480 | `最大 contig (染色体バックボーン)` |
| `molecule_classification.contigs[].evidence[].detail` | 7,782 | `46.8% vs 染色体 52.2%` |
| `dec_alerts.*_ja` (6 種) | 1,900 | `志賀毒素産生性大腸菌 / 腸管出血性大腸菌` |
| `dec_alerts.expec.groups_absent[].group` | 325 | `P線毛` |
| `integrons.orphan_elements[].note` / `.warnings[]` | 80 | `インテグラーゼもカセットも伴わない骨格断片` |
| `molecule_classification.warnings[]` | 12 | `解けなかった反復により FASTA が 20,324 bp 水増し` |
| `mlst.warnings[]` / `read_qc.warnings[]` / `pmlst…note` | 8 | `icd(12/12) に同一アリルの重複ヒットを検出` |
| `species_identification.warnings[]` / `.confidence_explanation` | 2 | `最も近い既知株は … 菌種の境界 95.0% に…` |

加えて API の `HTTPException(detail=…)` **36 箇所**が日本語 (`ApiError.message` として画面に出る)。

**これが本件で最も重い制約**: 上表は**過去の解析結果に文字列として保存済み**なので、
描画時に訳し直すことは原理的にできない。再解析しない限り旧検体は日本語のまま出る。

### 1.4 すでに英語を持っているもの

- `api/services/geography.py` の `JP_PREFECTURES` は `(コード, 日本語名, 英語名)` の 3 つ組を持ち、
  `/geography` は `{"code","label","en"}` を返している → **都道府県は追加作業ほぼ不要**。
- `dec_alerts` のフィールド名が `label_ja` / `title_ja` / `detail_ja` = **多言語を想定した命名だけ済んでいる**
  (`_en` は存在しない)。
- 菌種名・遺伝子記号・薬剤名は元から Latin/学名 → 翻訳対象外。
  遺伝子名の表記規則 (`lib/geneName.ts`, CLAUDE.md #54) も**言語非依存**なのでそのまま。

---

## 2. 設計

### 2.1 中核 — `frontend/src/lib/i18n.ts` (単一の真実源)

`sampleAlias.ts` と同じ形。**判定 (どの文言を出すか) はこのモジュールだけが持ち、
描画側は結果を出すだけ** (CLAUDE.md #19 の二重化事故の再発防止)。

```ts
export type Lang = 'ja' | 'en';

export function getLang(): Lang;              // React 外から (htmlExport など)
export function setLang(l: Lang): void;       // 永続化 + 通知 + <html lang> 更新
export function useLang(): Lang;              // useSyncExternalStore (getServerSnapshot 必須)
export function t(key: MsgKey, p?: Params): string;      // React 外からも呼べる
export function useT(): (key: MsgKey, p?: Params) => string;  // 言語を購読して再描画
export function fmtInt(n: number): string;    // toLocaleString の置き換え
export function fmtDate(d: string | Date, style?): string;
export function plural(n: number, one: MsgKey, other: MsgKey): string;
```

- 永続化キー: `localStorage['tarot.lang']`。初期値は `localStorage` → `navigator.language` → `'ja'`。
- **ログアウトでリセットしない。** `sampleAlias` はテナント分離キーなので `resetSampleAliases()` が
  必須だったが、言語は端末の設定であってグループ跨ぎの漏洩要因ではない。
- `getServerSnapshot` を必ず渡す — 渡さないと `renderToStaticMarkup` (A4 レポート) が落ちる
  (`sampleAlias` で同じ理由で必要になっている)。

### 2.2 カタログ — `lib/locales/ja.ts` / `en.ts`

```ts
// ja.ts
export const ja = {
  'nav.dashboard': 'ダッシュボード',
  'brief.notAssessed.title': '判定できなかった項目',
  'plasmid.dcj0.all': '表示中の {n} 本はすべて DCJ 0 (構造上区別できません)',
} as const;
export type MsgKey = keyof typeof ja;

// en.ts —— Record<MsgKey, string> にすることで **英訳の欠落を tsc がエラーにする**
export const en: Record<MsgKey, string> = { ... };
```

- 補間は `${}` ではなく **`{name}` プレースホルダ**。283 箇所のテンプレートリテラルを機械的に変換する。
  検体 ID・遺伝子名・数値は params として渡し、**文字列に埋め込まない** (訳文で語順が変わるため)。
- 文中の `<strong>` などは **`<b>` / `<i>` / `<br>` の固定 3 種だけ**許可し、
  JSX 側と `htmlExport` 側で**同じ 1 個のレンダラ**を通す (画面と書き出しで別実装にしない — #42)。
- 名前空間はファイル単位ではなく**画面/機能単位** (`brief.*`, `plasmid.*`, `cgsnp.*`, `integron.*`, `job.*`)。

### 2.3 なぜ i18next を入れないか

| | 自前 (~200 行) | i18next |
|---|---|---|
| React 外 (`htmlExport` / 純関数) | 素で可 | `i18n.t` で可 |
| キーの型安全 | **literal union で tsc が欠落を捕まえる** | 追加設定が要る |
| 既存規約との一致 | `sampleAlias` と同一 | 購読の仕組みが 2 系統になる |
| 複数形・語形 | `plural()` 1 個で足りる (英語の s だけ) | 強力だが本件では過剰 |
| 依存追加 | 0 | +40 KB 程度 |

→ **自前を推奨。** ただし将来 3 言語目や翻訳外注 (XLIFF) が視野に入るなら i18next の方が良い。
今のところ 2 言語・社内保守なので自前で足りる。

### 2.4 切替 UI

`App.tsx` のヘッダ右 (`app-header__user`、`+ 別アカウント` の隣) に
`日本語 / English` のセグメントトグル。ログイン画面 (`Login.tsx`) にも置く
(**ログイン前に切り替えられないと英語話者が最初の画面で詰む**)。

---

## 3. 段階

### Phase 0 — 基盤 ✅ **完了 (2026-09-11)**

1. `lib/i18n.ts` + `lib/locales/{ja,en}.ts` + `RichText` ヘルパ
2. ヘッダ / ログイン画面の切替 UI、`<html lang>` 追従、`document.title`
3. **`tools/i18n_scan.mjs`** — ソース中の未変換日本語 (JSX テキスト / 文字列リテラル) を列挙して
   残件を数える。許可リスト (`// i18n-ignore`) で例外を明示。**進捗をこの数で管理する。**
4. **`toLocale*` を `fmtInt` / `fmtDate` / `fmtDateTime` に置換 (実測 120 箇所)。**
   今は引数なし = 閲覧者のブラウザロケール依存で、日本語 UI でも英語圏の端末では別書式になっていた。

#### 実際に入ったもの

| ファイル | 役割 |
|---|---|
| `src/lib/i18n.ts` | 単一の真実源。`getLang` / `setLang` / `useLang` / `t` / `tIn` / `useT` / `plural` / `fmtInt` / `fmtNum` / `fmtDate` / `fmtDateTime` |
| `src/lib/locales/{ja,en}.ts` | カタログ。`en` は `Record<MsgKey,string>` なので**欠落・余剰を tsc がエラーにする** |
| `src/lib/richText.ts` | `<b>`/`<i>`/`<br>` のトークナイザ (JSX と HTML 書き出しで**共有**) |
| `src/lib/richHtml.ts` | 文字列組み立て側の入口。**params を必ずエスケープする** |
| `src/components/RichText.tsx` | 同じトークナイザで JSX を描く (`dangerouslySetInnerHTML` は使わない) |
| `src/components/LangSwitch.tsx` | ヘッダとログイン画面のトグル |
| `tools/i18n_scan.mjs` | 残件カウンタ (ベースラインでラチェット) |
| `tools/i18n_check.ts` + `run-i18n-check.mjs` | SSR 検証 (`npm run i18n:check`) |

npm script: `i18n:scan` / `i18n:list` / `i18n:update` / `i18n:check` / `typecheck`

#### 決めたこと (実装時に確定)

- **既定は `ja` 固定。`navigator.language` は見ない。** 英語ロケールの端末を使う
  日本語話者 (研究者に多い) が更新した途端に英語へ飛ぶのが最も驚きが大きいため。
  切替は明示のみ、`localStorage['tarot.lang']` に保存。
- **ログアウトでリセットしない** (`sampleAlias` と違い、言語はテナント分離キーではない)。
- **未定義キーはキー名をそのまま返す。空文字にしない** — 未翻訳が空欄になると
  「該当なし」と読める (#28 / #40)。値未指定のプレースホルダも `{name}` のまま残す。
- **数値は自動整形しない。** 呼び出し側が `fmtInt(n)` を通す (年号 2026 が "2,026" になる事故を防ぐ)。
- **`fmtInt`/`fmtNum` の既定フォールバックは `'-'`、日付は `'—'`** — 前者は
  SampleDetail が持っていたローカル整形関数、後者は既存の欄の埋め方に合わせた (意図的に別)。
- `en` の `Intl` ロケールは `en-GB` (日付が 11/09/2026、時刻は 24 時間表記)。

#### 実測: Phase 0 による表示の変化

| | 変化 |
|---|---|
| 整数 111 箇所 | **無し** (`ja-JP` も `en-GB` も `1,234,567`) |
| 日時 7 箇所 (日本語表示) | **ゼロ埋めが付く**: `2026/9/11 18:05:03` → `2026/09/11 18:05:03` |
| 日付 2 箇所 | ブラウザロケール依存 → `2026/09/11` に固定 |
| ブラウザタブ | `frontend` → `TAROT-Analyzer` (`index.html` の既定 lang も `en` → `ja`) |

#### 検証結果

- `./node_modules/.bin/tsc --noEmit -p tsconfig.app.json` → **エラー 0** (`npx tsc` は使わない)
- `npm run build` → 成功
- eslint → 新規追加ぶんの指摘 **0** (既存の `no-explicit-any` 等はいずれも未改変箇所)
- `npm run i18n:check` (SSR) → **全 22 項目 PASS**。NAS の実レポート **40 件 × 2 言語 = 80 通り**の
  A4 レポート + 詳細 HTML ビルドが例外 0。JSX と HTML 書き出しのリッチテキスト一致、
  params のエスケープ、`getServerSnapshot` 有りでの `renderToStaticMarkup` も確認。
- 実ブラウザ (`localhost:3000/login`) → トグルで `<html lang>` と `localStorage` が追従、
  **リロード後も復元**、`aria-label` が言語で切り替わることを DOM 実測。
- `npm run i18n:scan` → 残件 **2,048 件 / 51 ファイル** をベースラインとして記録。

#### 実装中に踏んだもの (次の Phase でも効く)

- **コードモッドの受け手切り出しで `new` が落ちた。** `new Date(iso).toLocaleString()` が
  `fmtDateTime(Date(iso))` になり、`Date(iso)` は**引数を無視して現在時刻の文字列**を返す
  = 無言で間違った時刻。前置キーワードを取り込むよう修正。
- **光学連鎖 `a?.b.toLocaleString()`** で `?` を受け手の切れ目と誤判定し
  `a?fmtInt(.b)` を生成。`?` の直後が `.` なら受け手の一部と見なすよう修正。
  こうした壊れ方は必ず構文エラーになるので tsc が全部捕まえた。
- **`import` の挿入位置**: 「最後の `import ` で始まる行」の直後に入れると、
  複数行 import の**内側**に刺さる。import 文の終端 (`} from '...'`) で判定すること。
- **既存のローカル関数と名前が衝突する。** `SampleDetail` の `const fmtInt` は
  コードモッドで**自己再帰**になった。同名のローカル定義があるファイルには import しない
  検査を入れ、当該ローカルは削除して共通版に一本化した (フォールバックを揃えたので見え方は同じ)。
- **`git stash` を検証に使わないこと。** 未追跡ファイルがある状態で pop が
  途中失敗する。lint の増減は「指摘の出ているファイルを自分が触ったか」で判断すれば足りる。

### Phase 1 — 非専門家向けの経路から ✅ **完了 (2026-09-11)**

1. アプリ枠: `App` / `Login` / `Dashboard` / `ErrorBoundary` / `ConfirmDialog` / `StatusBadge` (約 60 文字列)
2. **シンプルビュー + A4 レポート**: `sampleBrief.ts` (106) / `SampleBriefView` (52) /
   `briefBadges` (78) / `briefStyles` (44) / `briefReport` (12) / `BriefBadgeIcon`
   → ここで **レイアウトの再実測**を行う (§5)
3. `Results.tsx` (78) / `JobDetail` (27) / `NewJob` (24) / `DropZone` / `PipelineTimeline` (35)

#### 実績

残件 **2,048 → 1,515 件** (533 件を翻訳 / 51 → 32 ファイル)。カタログは **416 キー**。

| 範囲 | ファイル |
|---|---|
| アプリ枠 | `App` / `Login` / `Dashboard` / `ErrorBoundary` / `ConfirmDialog` / `ToolStatusPanel` / `printHtml` / `api.ts` |
| シンプルビュー + A4 | `sampleBrief.ts` / `SampleBriefView` / `briefBadges.ts` / `briefReport.ts` / `notifiableDiseases.ts` |
| 一覧・ジョブ | `Results` / `JobDetail` / `NewJob` / `DropZone` / `PipelineTimeline` / `SortHeader` / `DoradoJobDetail` |

#### 実装で決めたこと

- **既に英語だった文字列は日本語に訳さない。** 目的は英語対応であって日本語の推敲ではない。
  両言語で同じに出るだけなので害はなく、既存表示を勝手に変えない方を採った。
- **モジュール読み込み時に `t()` を呼ばない。** ラベル表 (`GLOSSARY` / `RULE_LABELS` /
  `PHASE_LABELS` / `STATUS_LABEL` / `CORE_SNP_LABEL` / `KEY_AMR_RULES`) は
  **値をアクセス時に解決する getter** にした。呼び出し側 (`GLOSSARY.mlst`) の
  書き方を変えずに言語切替へ追従できる。
- **ツール名は固有名詞なので翻訳しない。** 文言になっている項目だけ `labelKey` を
  持たせ、描画時に解決する (`ToolStatusPanel` / `PipelineTimeline` / `Results` の列定義)。
- **`t()` だけでは再描画されない。** `t` は購読しないただの関数なので、
  表示に使うコンポーネントは `useT()` か、少なくとも `useLang()` を呼んで購読する。
  `JobDetail` / `DropZone` / `PipelineTimeline` / `DoradoJobDetail` は購読のみの
  `useLang()` を先頭に置いた。`SampleDetail` の `buildSampleBrief` の `useMemo` には
  **`lang` を依存に足した** (忘れると本文だけ前の言語で残る)。
- **感染症法の区分は「値」と「表示」を分けた。** `NotifiableCategory` の値
  (`'5類定点'` 等) は判定に使う正準値なので不変。表示は
  `notifiableCategoryLabel()` が言語で切り替える。
- **感染症法の英訳は典拠付き。** NIID / JIHS "Infectious Disease Surveillance
  System in Japan" (NESID Program summary, 2018) の表記に統一した
  (`Category I`–`V` / `enterohemorrhagic Escherichia coli infection` /
  `severe invasive streptococcal infection` / `invasive meningococcal disease` /
  `carbapenem-resistant Enterobacteriaceae infection` 等)。
  対象 30 疾患すべてがこの 1 文書で確認でき、推測した訳語は無い。
- 種名だけで決まる疾患の `id` を**病名から ASCII に変えた** (`'ペスト'` → `'plague'`)。
  id は React のキーと `notify-{id}` に使うので、言語で変わってはいけない。

#### レイアウトの再実測 (Phase 1 の要件)

内容量で全 1,111 検体を採点し (`tools/i18n_rank.ts`)、**上位 150 検体**を
実ブラウザで測った。行数ではなく**描画される行数**で選ぶこと — JSON の
バイト数は contig 数などで膨らみ、高さと対応しない。

| | 日本語 | 英語 |
|---|---|---|
| A4 内容高さ (最大) | 251.4 mm | **254.9 mm** (+1.4%) |
| A4 で 1 枚に収まらない検体 | **0 / 150** | **0 / 150** |
| 画面の自然高さ 1280px (最大) | 653 px | **638 px** (英語の方が低い) |
| 画面の自然高さ 1920px (最大) | 720 px | **676 px** (同上) |

**A4 は英語がわずかに高く、画面は英語の方が低い。** 3 カラムの画面では
ラテン文字が細かく折り返せるぶん有利で、2 カラムの A4 では不利になる。
どちらも既存の枠を超えないので**フォントサイズは言語別にしていない**。

**測定器が発火するかを先に確かめること (#53)。** 最初の画面用ハーネスは
ラッパーに `overflow:auto` を置いて `scrollHeight` を見ていたが、
枠を 300px に縮めても検出 0 だった (`.brief` が枠を無視するため)。
**ラッパーではなく `.brief` 自身の自然高さ**で測り直した。

#### 検証

- `./node_modules/.bin/tsc --noEmit -p tsconfig.app.json` → **0**
- `npm run build` → 成功 / `eslint` の指摘数は Phase 0 前と**完全に同数** (新規 0)
- `npm run i18n:check` (SSR) → 全 PASS。実レポート 40 件 × 2 言語 = 80 通りが例外 0
- 実ブラウザ: 言語トグルで **リロード無しに再描画**され、`<html lang>` と
  `localStorage` が追従、往復して戻ることを DOM 実測
  (React の再描画は非同期なので、`click()` 直後ではなく待ってから読むこと)
- 英語版シンプルビューをスクリーンショットで目視確認

### Phase 2 — 詳細ビューと図 ✅ **完了 (2026-09-11)**

`SampleDetail` / `PlasmidProfileSection` / `CoreSnpSection` / `IntegronCard` /
`DecAlertsCard` / `GenomeMap`(+Section) / `MstGraph` / `PlasmidDistanceMap` /
`PlasmidStructure{Compare,Stack,Chain,Chrome}` / `GfaGraph` / `CoreSnpDbBrowser` /
`Admin` / `Pod5DirPicker` / 各ダイアログ、および純粋判定モジュール
(`plasmidMap` / `integronColors` / `betaLactamase` / `epiColors` /
`genomeMapUtils` / `plasmidStructureExport`)。

### Phase 3 — HTML 書き出し ✅ **完了 (2026-09-11)**

`htmlExport.ts` / `plasmidStructureExport.ts` の注記 / `printHtml.ts`。
画面と**同じカタログ**を通すので、片方だけ古くなる余地が構造的に無い (#19 / #42)。

#### 実績 (Phase 2 + Phase 3)

残件 **1,515 → 0 件**。カタログは **1,551 キー** (ja / en とも同数、tsc が保証)。

| | Phase 0 前 | Phase 1 後 | **Phase 3 後** |
|---|---|---|---|
| 未翻訳の日本語 (`npm run i18n:scan`) | 2,048 | 1,515 | **0** |
| カタログのキー数 | 0 | 416 | **1,551** |
| eslint の指摘数 | 259 | 259 | **259** (新規 0) |

#### 実装で決めたこと

- **d3 の描画 effect の依存配列に `lang` を足した** (`GenomeMap` / `MstGraph` /
  `PlasmidDistanceMap` / `PlasmidStructure{Compare,Stack,Chain}`)。
  これが Phase 2 最大の危険で、忘れると**図の中だけ前の言語のまま残る**
  (エラーも警告も出ない)。**実ブラウザで往復を実測して確認した** (下記)。
- **`t` という名前の局所変数を潰した。** d3 のエッジ (`(s, t, w)` → `(source, target, w)`)、
  `mgeTypeLabel(t)` → `(type)`、`pmlstCellHtml` のループ変数 `t` → `ty`。
  潰せない場所 (`SampleBriefView` / `PlasmidStructureChain` / `PlasmidProfileSection` /
  `SampleDetail` / `Admin`) は翻訳関数を `tr` に別名化した。
  **シャドウしても tsc は通る**ので、機械置換に頼らず全箇所を目で確かめること。
- **HTML 書き出しは React 外**なので `richHtml()` / `tIn()` 経由で引く。
  `renderToStaticMarkup` を使う A4 レポートだけは React 経路のまま。
- **`fmtInt` の既定フォールバックを `'-'` にした。** `SampleDetail` に同名の
  局所ラッパーがあり、機械置換で自己再帰になっていた。既定値を合わせてから
  ラッパーを削除したので**表示は不変**。

#### レイアウトの再実測 (Phase 3 後)

| | 日本語 | 英語 |
|---|---|---|
| A4 内容高さ (最大) | 251.4 mm | **254.9 mm** (+1.4%) |
| A4 で 1 枚に収まらない検体 | **0 / 150** | **0 / 150** |

Phase 1 の実測と変わらず。フォントサイズは言語別にしていない。

#### 検証

- `npm run i18n:scan` → **0 件 / 0 ファイル**
- `./node_modules/.bin/tsc --noEmit -p tsconfig.app.json` → **0**
  (`npx tsc` は型エラーを隠すので使わない — memory / #53)
- `npm run build` → 成功
- `eslint` → **259** = Phase 0 前と完全に同数 (新規の指摘 0)
- `npm run i18n:check` (SSR) → 全 PASS。
  **NAS の実レポート 48 件 × 2 言語 = 96 通り**の `htmlExport` ビルドが例外 0
  (フックの TDZ / 順序違反はここで捕まる — #44 / #46.3)
- **実ブラウザで d3 の言語追随を実測**: `GenomeMap` を props 直叩きする
  使い捨てハーネスを Vite dev に置き、トグル前後で SVG の `<text>` を読み比べた。
  `AMR: … (上) · MGE: … (下)` → `AMR: … (above) · MGE: … (below)` に変わり、
  `<html lang>` も `ja` → `en` に追随することを DOM で確認 (確認後にハーネスは削除)。
  **`requestAnimationFrame` は Browser ペインが隠れていると発火しない**ので
  待ちは `setTimeout` で行うこと。`click()` 直後の同期読みは React の
  非同期レンダー前の古い値を返す。

### Phase 4 — サーバー由来の文言 ✅ **完了 (2026-09-11)**

1. **API エラー (33 箇所)**: `HTTPException(detail=…)` を
   **`{code, params, message}`** の構造化 detail に変えた (`api/services/api_errors.py`)。
2. **`geography.py`**: `region_display` / `country_label` を**日英の両方**返すようにした。
3. **workflow の所見文**: `classify_molecules` / `classify_dec_pathotype` /
   `classify_integron` / `parse_mlst` / `classify_pmlst` にコードとパラメータを追加。
4. (計画外で見つかった分) **dorado の `phase_detail`** も同じ形にした。

#### 調査で前提が変わった — **旧レポートも英語化できる**

プランは「コードが無い旧レポートは日本語のまま」を前提にしていたが、
実測すると**表示に使う文言のほぼ全てに安定したコードが既に併記されていた**:

| 材料 | 旧レポートでの保有率 |
|---|---|
| `evidence[].code` / `guards[]` / `role` / `score` | **100%** (10,681 件) |
| `alerts[].id` / `pathotype` / `stx.risk` / `subgroups[].id` | 100% |
| `detected_markers[].gene` / `evidence[].gene` | 100% |

したがって**再解析なしで既存 1,111 検体も英語表示になる** (ユーザー決定)。
コードから文言を組み立て直す層が `frontend/src/lib/serverText.ts`。

**`molecule_classification.evidence[]` は画面にもエクスポートにも出ていない**
(表示されるのは `reason` だけ) ことも実測で分かった。8,734 件の `label` と
2,754 件の `detail` は**データとしてのみ存在**し、読んでいるのは
`backfill_molecule_classification.py` の差分表示だけ。そのため
`detail` のテンプレート (GC / 被覆 / 核心遺伝子) は訳していない。

#### 設計

- **判定は一切触っていない** (#19)。workflow は日本語 (`reason` / `label_ja` /
  `warnings`) を**従来どおり残したまま**、`reason_key` / `detail_keys` /
  `warning_keys` / `title_params` を**併記**する。
  - 日本語を残す理由: CLI の `backfill_molecule_classification.py` が
    `contigs[].reason` を運用者向けの差分表示に使っている。消すと読めなくなる。
- **フロントは「コードが引ければカタログ、引けなければサーバーの日本語」**。
  未知のコードで空文字を返さない (#28)。
- 画面と HTML 書き出しは `serverText.ts` の**同じ関数**を通る (#42)。
- **地域ラベルをサーバーに選ばせない。** 言語切替は再取得を伴わないクライアント
  側トグルなので、`Accept-Language` で片方だけ返すとその欄だけ前の言語で残る
  (#41 と同型)。`region_display` と `region_display_en` を両方返し、描画時に選ぶ。
- **`api_error` は `message` (日本語) を必ず残す。** curl / ログ / 旧クライアントが
  読めなくなるのを防ぐため。フロントもキーが無ければこれに退避する。

#### 二重化を縛るテスト

`workflow/tests/test_i18n_server_parity.py` が
**workflow の日本語 == ja.ts の値**を全数検査する (#52 の `_fallback_contig_key`、
#42 の色定義と同じ型)。日本語を変えるときは両方直すこと。片方だけだと落ちる。

#### 実装で踏んだもの

- **`score 1.0` vs `1`。** Python は `round(score, 2)` の float をそのまま埋めるので
  整数でも `1.0`。JS の `String(1)` は `1` なので、表示が 19 件ずれた。
- **`size_cap` / `genome_budget` の理由文は再現できない。** 文中に config の閾値が
  入るのにレポートが保存していない。さらに `size_cap` が発火していても
  「score が閾値以上のときだけ」上限超過の文になる。**推測で数字を書かず**
  サーバーの日本語へ退避させ、新しい workflow は `reason_params` で数値を渡す。
- **ExPEC の見出しの分母は必要群数 (2) ではなく定義群の総数 (5)。**
- **ExPEC の説明文だけ日本語で句点の後に空白が入らない** (分類器が隣接文字列
  リテラルで連結しているため)。区切りをカタログのキーにして一致させた。
- **`・` (U+30FB) はカタカナ範囲に入る。** 検証スクリプトの「日本語が残っているか」
  判定が誤検知した。区切り記号なので判定から除き、**英語では `, ` に変えた**。
- **`m.pathotype` (`ExPEC` / `STEC/EHEC`) は訳さない。** 言語非依存の略号で、
  Phase 1 で決めた「既に英語のものは触らない」に従う。

#### 検証

| | |
|---|---|
| `npm run i18n:scan` | **0 件** |
| `tsc --noEmit` (直接実行) | **0** |
| `npm run build` | 成功 |
| `eslint` | **259** = 着手前と完全に同数 |
| `npm run i18n:check` (SSR) | 全 PASS |
| **`npm run i18n:parity` (新規)** | 下記 |
| `workflow/tests/test_i18n_server_parity.py` | ja.ts 1,885 キーに対し全一致 |
| workflow / api の既存テスト | 107 + 5 ファイル すべて PASS |

**`i18n:parity` が本体。** NAS 全 **1,111 検体**の実レポートに本番の解決関数を当て、

- **日本語モード: 115,116 件すべてサーバーの文字列と一字一句一致** (10 項目 PASS / 不一致 0)
  → コードから組み立て直しても意味が変わっていないことの証明
- **英語モード: 日本語が残るのは 88 / 113,393 (0.08%)**
  → 全て `size_cap` / `genome_budget` の理由文。新規解析では `reason_params` で解決する

実ブラウザでも確認した (使い捨てハーネス、確認後に削除): 実在の検体 19403 の
DEC アラートカードが**見出し・副題・説明文・免責文・遺伝子チップまで英語で描画され**、
トグルを往復させると元の日本語に**完全に一致して戻る**。

### Phase 5 — 検証 (§5)

**適用範囲: 全画面 + サーバー由来の文言 (Phase 1–4) — 確定。完了。**

各 Phase の「検証」節に実測値を残した。以後の変更では次の 4 つを回帰として通すこと:

| コマンド | 何を守るか |
|---|---|
| `npm run i18n:scan` | フロントに新しい日本語リテラルが入っていない (ベースラインでラチェット) |
| `./node_modules/.bin/tsc --noEmit -p tsconfig.app.json` | 英訳の欠落・余剰 (**`npx tsc` は使わない**) |
| `npm run i18n:check` | SSR で描画例外 0 (フックの TDZ / 順序違反) |
| **`npm run i18n:parity`** | **実レポートで日本語モードの文言がサーバーと一字一句一致する** |
| `python3 workflow/tests/test_i18n_server_parity.py` | workflow の日本語と ja.ts が一致する |

`i18n:parity` と `test_i18n_server_parity.py` は Phase 4 で入れたもので、
**サーバーの文言とカタログの二重化**を縛る。日本語を変えるときは
workflow と ja.ts の両方を直すこと。

---

## 4. 方針 (2026-09-10 確定)

### 4.1 レポート JSON に焼き込まれた日本語 (§1.3) — **A 案を段階的に (確定)**

| 案 | 内容 | 旧検体 | コスト |
|---|---|---|---|
| **A (推奨)** | workflow の文言を **コード + パラメータ**に変え、フロントのカタログが両言語を持つ。コードが無い旧レポートは既存の日本語文字列をそのまま出す | 日本語のまま | 中 (workflow 6 ファイル + backfill 判断) |
| B | サーバーが `label` と `label_en` を両方書く | 日本語のまま | 小だが JSON が肥大 (1 検体あたり evidence label ~145 件) |
| C | 当面サーバー文言は日本語のまま。UI だけ英語化 | 日本語のまま | 0 |

**確定: Phase 1–3 は C の状態で出し、Phase 4 で A に進む。**
A で触るのは `classify_molecules.py` / `classify_dec_pathotype.py` / `classify_integron.py` /
`parse_mlst.py` / `run_mash_screen.py` / `per_sample_report.py` の**文言生成箇所のみ**で、
**判定ロジックは一切変えない** (#19)。
遡及 backfill は `molecule_classification` だけで 17k 件/120 検体規模になるため、
やるなら**文言だけ差し替える専用 backfill** (`backfill_sample_reports.py --force` は
paidb / plasann 等を消すので使わない — #28) を別途書く。**まずは backfill しない前提で計画。**

### 4.2 日本固有のドメイン用語 — **公式英訳 + 注記 (確定)**

`lib/notifiableDiseases.ts` (95 文字列) は**感染症法**の類型 (五類感染症 等) で、
日本の法制度そのもの。英語 UI で何を出すか:

**確定: ① 厚労省の公式英訳を出し、「日本の感染症法 (Infectious Diseases Control Law) に基づく分類」と注記する。**

- 英訳は**推測で作らず**、厚労省の英語版告示に載っている名称を典拠付きで `notifiableDiseases.ts` に併記する
  (典拠不明のものは日本語のまま残し、`en_source: null` で「未確定」と分かるようにする — 推測の訳語を
  法令用語として出す方が無訳より有害)。
- 類型名 (五類感染症 → Category V) と疾病名 (腸管出血性大腸菌感染症 → Enterohemorrhagic *E. coli* infection)
  は別レイヤーなので、カタログ上も分ける。

### 4.3 翻訳の粒度

「所見の説明文 (長文の注記) まで訳すか、ラベル・見出し・ボタンに留めるか」。
本アプリは**注記文に一番情報がある**設計 (「陰性ではなく検査不能です」等 — #28 / #40) なので、
**注記文まで訳さないと英語 UI は誤読を招く**。全部訳す前提で見積もっている。

---

## 5. 検証 (このリポジトリで既に確立している型を使う)

1. **未変換の残件**: `tools/i18n_scan.mjs` が 0 (例外は許可リストに明示)。
2. **英訳の欠落**: `en.ts` を `Record<MsgKey, string>` にしてあるので tsc がエラーにする。
   実行は **`./node_modules/.bin/tsc --noEmit -p tsconfig.app.json` を直接**
   (`npx tsc` はエラーがあっても "No errors found" を返す — memory / #53)。
3. **レンダー例外**: `vite build --ssr` で `buildSampleBrief` / `buildBriefReportHtml` /
   `htmlExport` を **NAS 全 1,111 検体 × 2 言語**に当てて例外 0。
   フックの TDZ・順序違反はここで捕まる (#44 / #46.3)。
4. **レイアウトの再実測 (最重要)**:
   #53 で A4 1 枚 (最大 270.4 mm / 上限 277 mm) と 1280×720 スクロールなし
   (12.5 px は溢れ 0 / 13 px で 7 件溢れ) を**実測で決めている**。
   英語は文字数が増え、日本語は 1 文字が全角幅 — **どちらが長くなるかは文字列ごとに違うので推測しない**。
   `frontend/__verify/screen.html` で **言語 × 1280/1440/1920 を全部測り直す**。
   `briefStyles.ts` のフォントサイズは**言語別に持てる形**にしておく。
   測定器が実際に発火することを先に確認すること (900×480 に縮めて全件で溢れ検出が出るか)。
5. **実ブラウザでのトグル往復**: 言語を切り替えて戻し、
   **d3 の図が両方とも追随すること** (図だけ前の言語で残る症状の確認)。
6. **数値・日付**: `fmtInt` / `fmtDate` 置換後、両言語で桁区切り・日付書式が意図どおりか。

---

## 6. やらないこと (明示)

- **利用者が入力した文字列は訳さない**: 検体表示名 (#18)、施設名、海外の地域ラベル (`region_label`)、
  ジョブ名、コメント。
- **学名・遺伝子記号・薬剤名・ST 番号**: 元から言語非依存。`geneName.ts` の表記規則もそのまま。
- **パイプラインの生ログ** (SSE ログパネル): 外部ツールの出力なので訳さない。
  `snakemake_runner.py` / `dorado_runner.py` の `[TAROT-API]` 行と、dorado の
  `phase_detail` に生ログをそのまま載せる経路も同じ扱い (キーを付けていない)。
- **CSV 取り込みの列名エイリアス** (`検体名` / `分離日` …): 入力の照合パターンで
  あって表示文言ではない。英語の列名は元から受け付ける。
- **`schemas.py` の `Field(description=…)`**: OpenAPI のドキュメントで UI には出ない。
- ~~**過去レポートに焼き込まれた日本語の遡及翻訳**~~ → **Phase 4 で可能になった。**
  表示に使う文言には安定したコードが既に併記されていたため、再解析なしで
  既存 1,111 検体も英語で出る (残るのは 0.08% = `size_cap` / `genome_budget` の理由文だけ)。
- **`molecule_classification.evidence[].detail`**: 画面にもエクスポートにも出ておらず、
  読んでいるのは CLI の差分表示だけなので訳していない。
- **CLAUDE.md / コード中のコメント (2,862 行)**: 開発者向けなので日本語のまま。

---

## 7. 主な落とし穴 (このリポジトリの既往に基づく)

| 罠 | 出典 | 対策 |
|---|---|---|
| 画面と HTML 書き出しで文言を別実装にする | #19 / #42 | カタログを 1 つにし、両方が同じ `t()` を通す |
| d3 effect の依存に `lang` を入れ忘れ → 図だけ前の言語 | #41 | 依存配列に入れる。トグル往復で実ブラウザ確認 |
| フックを早期 return の後に置く / TDZ | #44 / #46.3 / #53 | `useT()` は必ずフック領域の先頭。SSR 検証で捕まえる |
| `npx tsc` が型エラーを隠す | memory / #53 | `./node_modules/.bin/tsc` を直接叩く |
| A4 1 枚・1 画面の実測値が英語で崩れる | #53 | 言語ごとに再実測。フォントサイズを言語別に持てる形に |
| 「未翻訳」と「該当なし」が区別できなくなる | #28 / #40 | キー未定義時は**キー名をそのまま出す** (空文字にしない)。scan で 0 にする |
| テンプレートリテラル中にバッククォートを書いて CSS が壊れる | #53 | カタログにコードを書かない。注記は `'` で書く |
