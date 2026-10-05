# デモセッション (プロモーション用のアカウントとデータセット) の計画

**目的**: 手持ちのデータが無い利用候補者に、TAROT-Analyzer の特徴を本物の画面で見てもらう。

## 決定事項 (2026-10-05)

| 項目 | 決定 |
|---|---|
| 提供形態 | 本番 (公開サーバー) に**閲覧専用**のデモグループを置く |
| データ | **MRSA = JAC-AMR 論文 (TAROT 検証) の 34 株** (公開済み)。**プラスミド = 過去の解析株 (toho_micro_id の AA002 群)**。どちらも既存のリードからデモグループへ名前を付け替えてコピーし、**デモグループで解析し直す** (2026-10-05 決定) |
| アクセス | **候補者ごとに個人アカウント** (招待 → 申請 → 承認)。2 段階認証あり・有効期限つき |
| 見せたい特徴 | プラスミドの伝播 / cgSNP の系統解析とアウトブレイク / 菌種別のタイピング / レポートと操作性 (4 つすべて) |
| ゲノム配列 | **デモ利用者には見せない** (コンティグ・Bakta / PlasAnn の配列ファイルはダウンロード不可。結果の画面だけ) |
| 参照の無い ST | **「参照ゲノム無し」で止まってよい** (STany の参照は置かない) |
| MiSeq のリード | 在処は不明 → ステージングツールの dry-run で確かめ、無ければ SRA から取得 |

## 1. アクセスの仕組み (実装済み: tarot-analyzer `claude/demo-readonly-group`)

### 構成
- **デモグループ** (`groups.demo = 1`)。所属者のうち **admin 以外は閲覧専用**になる。
- **管理用アカウント** (例: `demo_curator`、role=admin、デモグループ所属、院内 LAN からのみ)。
  デモデータの解析・メタデータの登録・候補者の招待を行う。
  連絡先は管理者のアドレスを共用できる (`TAROT_SHARED_CONTACT_EMAILS`, CLAUDE.md #73)。
- **候補者のアカウント**。管理用アカウントからの招待で申請し、管理者が承認する。
  承認した時点で有効期限 (`TAROT_DEMO_ACCOUNT_DAYS`、既定 30 日) が入る。

### 閲覧専用の守り方
- 判定は `api/demo_mode.py` の 1 か所だけ。ログイン時にセッションへ `read_only` と期限を書き込み、
  **全ての認証付き API が通る `require_session` が GET / HEAD / OPTIONS 以外を 403 にする**。
  書き込み API を新しく足しても、自動的に拒否される側に入る。
- 閲覧専用でも許す書き込み (許可リスト): 2 段階目の認証・連絡先メールの確認・
  自分のパスキー・ログアウト。
- **塩基配列は渡さない** (GET でも 403、`demo_mode.sequence_blocked`): コンティグの FASTA と ZIP、
  Bakta の出力 (fna/faa/gbff/gff3/json — gff3 は末尾に ##FASTA を持つ)、PlasAnn の出力 (gbk/gbff)。
  出力ファイルは配列を含まない拡張子 (Bakta の tsv/txt/log、PlasAnn の csv/png) だけを許す許可リスト。
  アセンブリグラフ (GFA) は API が配列列を `*` に置き換えて返すので対象外。画面のダウンロードボタンも隠す。
  デモグループの admin (解析担当) は取得できる。
- **招待は許さない**。招待一覧も見せない。招待の宛先は他の候補者のメールアドレスだから。
- 期限が切れたアカウントはログインできない (403)。ログイン中に期限が来たセッションは 401 になる。
- テスト `api/tests/test_demo_mode.py`。**本物のアプリの全ルートを走査**して、許可リストに
  想定外の書き込み API が入っていないこと、セッションを要求しない書き込み API が増えていないことを確かめる。
- 画面: ヘッダー直下に常設の案内 (「デモアカウント (閲覧専用)」「分離日・施設・材料・患者 ID は架空の値」
  「有効期限」)。New Job と Admin は隠す。Results では削除・cgSNP 実行・Bakta・メタデータの取り込みと編集・
  表示名の編集を隠す。**隠すのは入口だけで、拒否はサーバーが行う**。隠しきれていないボタンを押しても 403 になる。

### 運用コマンド (TAROT-ORCH)
```
python -X utf8 tools/manage_accounts.py --env-file C:/TAROT/config/tarot.env create-admin demo_curator --group-name "TAROT Demo"
python -X utf8 tools/manage_accounts.py --env-file ... groups                       # グループ ID を確認
python -X utf8 tools/manage_accounts.py --env-file ... set-demo-group <group_id> on
python -X utf8 tools/manage_accounts.py --env-file ... set-expiry <候補者> 30          # 延長 / none で期限なし
```
`set-demo-group` は**次のログインから**効く (ログイン中のセッションには効かない)。
すぐに効かせたい場合は、デモデータの準備が終わってから候補者を招待すればよい。

## 2. データセットの設計

### パイプラインの制約から決まる条件
| 見せたいもの | 必要な入力 | 理由 |
|---|---|---|
| プラスミドの距離マップ・構造比較・菌種をまたぐ伝播 | **閉環したプラスミド** (ONT のリード、または完全長の公開アセンブリ) | 環状に閉じていない contig は plasmid DB に登録されない (`require_circular`, #37.1)。Illumina だけでは「照会のみ」になる |
| cgSNP (MST・距離行列・系統樹) | **リード** (Illumina か ONT)。1 つの species/ST 群に 4 株以上、できれば 10〜20 株 | 完全長アセンブリ入力では cgSNP を回さない。系統樹は `min_strains`=4 以上、それ未満では距離行列だけ (#31) |
| Salmonella の血清型・cgMLST | Salmonella のリードが数株 | SeqSero2 と chewBBACA は Salmonella にだけ走る (#10) |
| STEC の病原型アラート | 大腸菌 (stx / eae 陽性) | #33 |
| ONT と Illumina の比較 | 同じ株を両方で読んだ組 | #37.3 (同一分離株で 0〜2 SNP) |

- **DB はグループごとに分かれる** (`{グループのルート}/db/bam_db`, `db/plasmid_outbreak`)。
  デモの解析結果が既存グループの系統樹や照会に混ざることはない。参照ゲノム (`representative_genomes`) は共有。
- 1 群の株数は 30 株未満に抑える (phylo の所要は株数の約 1.76 乗、#58)。

### データセット (2026-10-05 決定)

**採らなかった案**: ロンドンの IMP 産生 CPE (PRJEB38818, J Infect Dis 2024, doi:10.1093/infdis/jiae019) は
**Illumina のみで閉環プラスミドが無い** (論文の限界に明記)。TAROT は環状に閉じていない contig を
plasmid DB に登録しない (#37.1) ため、主役の距離マップ・構造比較が出ない。

#### A. MRSA — TAROT 検証論文の 34 株 (cgSNP・逐次解析・ONT/Illumina 比較)
出典: Tracking Antimicrobial Resistant Organisms Timely: a workflow validation study for successive
core-genome SNP-based nosocomial transmission analysis. JAC-AMR 2025 (doi:10.1093/jacamr/dlaf069)。
東邦大学医療センター大森病院の MRSA 34 株を MinION (R10.4.1) と MiSeq の両方で読んだもの。SRA 公開済み。

| ST | 株 (TUM 番号) | 見せ場 |
|---|---|---|
| ST8 (14) | 20816 20817 20818 20823 20888 20914 20929 20963 22173 22182 22698 22699 22705 22721 | 伝播が強く疑われる組 (cgSNP <5) が 4 組 + 疑い 3 組。系統樹は 4 株以上で出る |
| ST1 (10) | 20819 20820 20825 20913 20926 20967 22178 22188 22744 22750 | 伝播が強く疑われる組が 4 組。耐性遺伝子を載せた約 21 kb の環状プラスミドが単量体と 2 量体で現れる (論文本文、#49 の AA411 = 21,326 bp) |
| ST5 (5) | 22457 22458 22701 22702 22707 | 伝播が強く疑われる組が 2 組。SCCmec II |
| その他 (5) | 22723 (ST1516) / 20915 (ST2725) / 22741 (ST4143) / 22749 (ST2764) / 22730 (ST97) | 参照の無い ST の扱い (cgSNP は「参照ゲノム無し」で止まる。論文の bbsplit 分類とは挙動が違う) |

- 検体名は**論文と同じ `TUM20816` 形式**にする (論文の表と照合できるように)。
- **ONT 34 株すべて + MiSeq 4 株** (`TUM20914_MiSeq` のように別検体)。MiSeq は ST8 の伝播組の両方と
  ST1 の伝播組の両方を選ぶ (具体的な組は論文の補足表 / 既存の距離行列から決める)。
  ONT と Illumina は同じ BAM 群に同居し、同じ株が 0〜2 SNP になることを見せる (#37.3 / #38)。
- 既存の解析結果は NAS にある (CLAUDE.md の 20914 / 22173 / 22188 などがこの 34 株)。リードの在処は
  各検体の `results/{検体}/input_class.json`。**MiSeq のリードが NAS にあるかは分かっていない**
  (2026-10-05)。確かめ方は 2 通り:
  - マニフェストに `kind=illumina` の行を書いてステージングツールを **dry-run** で回す。
    元の `input_class.json` に短鎖リードが無ければ、その行が「illumina の入力がありません」で NG になる
    (コピーは何も起きない)。
  - ワーカーで直接見る (読むだけ):
    `for f in /mnt/nas/tarot/accounts/*/results/{20914,22173}*/input_class.json; do python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(sys.argv[1], d.get("mode"), bool(d.get("short_reads")))' "$f"; done`
    (`mode=hybrid` または別検体 `*_Illumina` / `*_MiSeq` の `mode=short_read` なら在る)。
  無ければ SRA から取得して、ファイルの組をマニフェストの `source` に直接書く
  (要確認: ワーカーに sra-tools があるか。無ければ ENA の FASTQ を院内の PC で取得して NAS に置く)。

#### B. プラスミド — toho_micro_id の AA002 群 (菌種をまたぐ伝播)
- IncL/M・blaIMP-1・約 76.7 kb の閉環プラスミドが **14 菌種・34 株**に分布し、DCJ 0 の群が
  **11 菌種にまたがる** (#41 / #55)。距離マップ・構造比較・連鎖表示の見せ場がそろう。
- **15〜20 株に絞る**: DCJ 0 の群から菌種が重ならないように 8〜10 株、DCJ が 0 でない株
  (例: 19403 の 52 kb 反転、17575 の挿入) を 3〜4 株、別クラスタの対照を 2〜3 株。
  候補の一覧は toho_micro_id の plasmid DB の `index.tsv` (`primary_cluster_id` = AA002) から作る。
- 検体名は **`DEMO-P01` 形式に付け替える** (院内の検体番号を候補者に見せない)。
  対応表はステージングツールが**手元のファイル**に書き、NAS のデモグループには置かない。
- 院内株なので**ゲノム配列はデモ利用者に見せない** (2026-10-05 決定)。閲覧専用のセッションでは
  配列のダウンロードを止めてある (上の「閲覧専用の守り方」)。見えるのは解析結果の画面だけ。

合計 約 55〜60 検体 (MRSA 38 + プラスミド株 15〜20)。

### 架空のメタデータ (色分け軸・同一患者・地域を見せるため)
- 取り込みテンプレート (Results → メタデータ取り込み) で登録する。
  施設名は「デモ病院 A / B / C」、地域は都道府県を 2〜3、分離日は 12〜18 か月に分散、
  材料は血液・尿・便・環境などを混ぜる。
- 符号化患者 ID は `DEMO-P001` 形式 (数字だけの ID は「院内の患者番号の疑い」の警告が出る、#69)。
  **同一患者の組を 1〜2 組**入れて、MST とプラスミド距離マップの紫の破線を見せる。
- MRSA は**論文の逐次解析の順番**に沿って分離日を並べると、cgSNP の窓 (分離日の新しい順) と
  系統樹の育ち方が論文の図 3 に近づく (順番は論文の補足表で確認)。
- マニフェストのメタデータ列にそのまま書けば、ステージングツールが取り込み用の CSV を出す。
- 本来のメタデータ (国・年) と矛盾してもよいが、画面の案内が「架空の値」と常に表示する。
  **実在の施設名・地名の組み合わせで実在の症例に見えないようにする。**

## 3. 手順 (作業はすべて院内 LAN から)
1. `create-admin demo_curator` → `set-demo-group <id> on` (上の運用コマンド)。
2. **マニフェスト (TSV) を作る**。列は `demo_name / kind / source` + 任意のメタデータ列
   (`isolation_date / region / facility / specimen / patient_code`)。`source` は元の検体の
   results ディレクトリ (例 `/mnt/nas/tarot/accounts/toho_omori/results/20816`)。
   元の検体がどのグループにあるかは `ls -d /mnt/nas/tarot/accounts/*/results/20816` で探す。
3. **ワーカーでステージングツールを回す** (tarot-analyzer `tools/stage_demo_inputs.py`):
   ```
   python3 tools/stage_demo_inputs.py manifest.tsv \
       --dest-root /mnt/nas/tarot/accounts/<デモグループ> --batch demo_20261005 \
       --metadata-out demo_metadata.csv --mapping-out ~/demo_mapping.tsv      # dry-run
   python3 tools/stage_demo_inputs.py ... --apply
   ```
   リードを `uploads/demo_20261005/<デモ名>/` にコピーする (ONT = `<名前>_ont_runN.fastq.gz`、
   MiSeq = `<名前>_runN_R1/R2.fastq.gz`)。コピーしながら gzip を検査し、壊れていれば止める (#50)。
   同じ名前・同じサイズのファイルは飛ばすので、途中で止まっても再実行してよい。
4. `demo_curator` で New Job → 入力ディレクトリに `uploads/demo_20261005` を指定。**Defer cgSNP phylo** を付ける
   (#58 / #60)。全検体が終わってから Results で ST ごとに cgSNP を実行する (#68 で 1 群 1 回にまとまる)。
5. プラスミド関連性 (クラスタリング) をグループ全体で実行する (#42.1)。
6. `demo_metadata.csv` を Results のメタデータ取り込みで読み込む。
7. 候補者役のテストアカウントで確認する: 案内が出ること / 書き込みが 403 になること /
   見せ場の画面 (下の巡回順) がすべて描けること / **院内の検体番号がどこにも出ないこと**
   (JobDetail・プラスミド DB ブラウザ・cgSNP DB ブラウザ・HTML 書き出し)。
8. 候補者を `demo_curator` のアカウント設定から招待する。

## 4. 見せ場の巡回順 (候補者向けの案内文に使う)
1. Results 一覧 → 検体を 1 つ開いて**シンプルビュー / A4 レポート** (#53)
2. 同じ検体の詳細ビュー: AMR とβ-ラクタマーゼの機能型分類 (#56)、インテグロン (#46)、Genome Map
3. **プラスミド株 (DEMO-P..) の Plasmid & Replicon Map → 距離マップ**: 菌種で色分けし、同じ IncL/M・blaIMP-1 が
   DCJ 0 のまま 10 菌種以上にまたがっているのを見せる (#41 / #55)。構造比較・連鎖表示で反転と挿入を見せる (#42)
4. **MRSA の cgSNP**: ST8 / ST1 / ST5 の系統樹・MST・距離行列。伝播が強く疑われる組 (<5 SNP)、
   施設・分離日での色分け、同一患者の破線 (#69)。ONT と MiSeq の同じ株が 0〜2 SNP であること
5. MRSA の SCCmec・毒力遺伝子、プラスミド株のインテグロン (blaIMP-1 カセット、#46)
6. 日英切替

## 5. 未決事項 / リスク
- [ ] MRSA 34 株の元の検体の在処 (グループ) と、MiSeq のリードが NAS にあるか
      (ステージングツールの dry-run で確かめる。無ければ SRA から取得)。
- [ ] AA002 群から 15〜20 株を選ぶ (index.tsv から)。
- [x] 院内株のゲノム配列はデモ利用者に見せない (決定・実装済み: 閲覧専用では配列のダウンロードを 403)。
      **解析結果 (AMR 遺伝子・プラスミドの構造図など) を外部に見せてよいかの施設の確認は別途必要。**
- [x] cgSNP の参照が無い ST (ST1516 / ST2725 / ST4143 / ST2764) は「参照ゲノム無し」で止まってよい (決定)。
      STany の参照は置かない。論文の bbsplit 分類とは挙動が違うことを案内文で一言断る。
- [ ] 候補者の 2 段階認証: パスキーまたは認証アプリの登録が必要で、デモとしては手間がかかる。
      案内文で手順を示す (共有アカウントにはしない、#62/#70)。
- [ ] 1 ログインにつきワーカーへの SSH 接続を 1 本使う。同時に多数の候補者が使う場合の上限
      (sshd の `MaxSessions`・#67 のチャネル上限) は、招待の人数で調整する。
- [ ] 閲覧専用で隠していないボタン (SampleDetail の再解析系、Plasmid DB / cgSNP DB の削除系など) は
      押すと 403 のエラー表示になる。気になれば画面ごとに隠す (サーバー側の守りは完了している)。
- [ ] HTML / CSV の書き出しは閲覧専用でも使える (患者 ID は既定で含めない、#69)。架空の値なので問題は無いが、
      書き出したファイルにもデモである旨を入れるかどうかは未決。
