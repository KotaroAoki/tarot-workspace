#v3.2 (after MRSA v4.1 )
#240808
#逐次解析 with sliding dataset up to 36 strins isolated within 3 monthes 
#ONT
#STEC
#解析するごとにデータベースをアップデート
#自動的に類似配列を検出してデータベースとして遺伝的関連性を解析
#引数1に菌株ID, 引数2にfast5 あるいはfastqが入っているフォルタのフルパス
#カレントディレクトリに新しくアウトプットディレクトリを作成
#bam_listはソートしてから出力
#name_listは引数1で入力した値のみに限定して出力
#downsampling機能を搭載 (downsampling rateが>=1のとき実施しないようにアップデート*)
#fastqのsimulateをwgsimからwgsimへ変更
#mplileup paralele

conda activate py39

#結果出力ディレクトリの作成とパス取得
output_dir=`date +%Y%m%d%H%M`
mkdir $output_dir
cd  $output_dir
output_dir_fullpath=`pwd` 
cd ..


###変数のセット###
start_dir_fullpath=`pwd` 
start_dir_name=`basename $start_dir_fullpath`
reference_dir="/mnt/c/ftproot/DB/STEC_reference_strain_genome/" 
bam_dir="/mnt/c/ftproot/DB/STEC_bam"
TOOLSPATH=$HOME"/program"
################


###解析開始###
cd $2

#カレントディレクトリ
cfullname=`pwd`
cname=`basename $cfullname`


#.fastq解凍
unpigz -f *.gz

#cat
cat  {"fastq_runid_"*,*"barcode"*,*"RBK114"*}.fastq > cat_reads.fastq
#Nanoplot reads QC (before trim)
NanoPlot --fastq cat_reads.fastq --loglength -o cat_reads_nanoplot_results
#Nanofilt
NanoFilt -q 15 --headcrop 75 -l 5000 < cat_reads.fastq > cat_reads_trimmed_q15_minlen5k.fastq
#Nanoplot reads QC (after trim)
NanoPlot --fastq cat_reads_trimmed_q15_minlen5k.fastq --loglength -o cat_reads_trimmed_q15_minlen5k_nanoplot_results


#ダウンサンプリング (5Mbのゲノムに対して約x100のdepthになるように自動計算してダウンサンプリング)
# Step 1: Calculate the average read length
total_read_nucleotide=`grep "Total bases" cat_reads_trimmed_q15_minlen5k_nanoplot_results/NanoStats.txt | awk -F":" '{print $2}' | perl -pe 's/ |\,//g'`
# Step 2: Calculate the number of reads needed to achieve 100x coverage
# Formula: (genome size * coverage) / (2 * average read length)
genome_size=5000000
coverage=100
target_nucleotide=$((genome_size * coverage))
sampling_rate=$(echo "scale=5; $target_nucleotide / $total_read_nucleotide" | bc)
# Step 3: Downsample the input FASTQ files
if (( $(echo "$sampling_rate >= 0 && $sampling_rate < 1" | bc -l) )); then
    # sampling_rateが0から1未満の場合に実行されるコマンド
    seqkit sample -p $sampling_rate cat_reads_trimmed_q15_minlen5k.fastq > cat_reads_trimmed_q15_minlen5k_depth100.fastq
elif (( $(echo "$sampling_rate >= 1" | bc -l) )); then
    # sampling_rateが1以上の場合に実行されるコマンド
    cat cat_reads_trimmed_q15_minlen5k.fastq > cat_reads_trimmed_q15_minlen5k_depth100.fastq
fi



#セルフエラーコレクション
dechat -i cat_reads_trimmed_q15_minlen5k_depth100.fastq -o cat_reads_trimmed_q15_minlen5k_depth100_dechat -t 36

#fasta to fastq using wgsim
wgsim -h -1 300 -2 300 -N1000000 -e0 -r0 -R0 -X0 -d0 cat_reads_trimmed_q15_minlen5k_depth100_dechat.ec.fa cat_reads_trimmed_q15_minlen5k_depth100_dechat_wgsim_R1.fastq cat_reads_trimmed_q15_minlen5k_depth100_dechat_wgsim_R2.fastq




#最適なreferenceを探す ($reference_dir内のすべてのゲノムファイル ".fasta"を指定)
#MLST only E. coli just in case
rm -f cat_reads_trimmed_q15_minlen5k_depth100_dechat_wgsim_stringMLST.txt
stringMLST.py --predict -P /home/mbuser/program/stringMLST/datasets/Escherichia_coli_1/Escherichia_coli_1 -1 cat_reads_trimmed_q15_minlen5k_depth100_dechat_wgsim_R1.fastq -2 cat_reads_trimmed_q15_minlen5k_depth100_dechat_wgsim_R2.fastq -o cat_reads_trimmed_q15_minlen5k_depth100_dechat_wgsim_stringMLST.txt


MLST=`awk 'NR>1 {gsub(/\*/, "", $1); print $9}' cat_reads_trimmed_q15_minlen5k_depth100_dechat_wgsim_stringMLST.txt`

db_STs=`ls $reference_dir | awk -F'[.]' '{print $1}' | awk -F'[_]' '{print $1}' | sort | uniq`

found=0
for db_ST in $db_STs; do
    if [[ "$db_ST" == ST"$MLST" ]]; then
        found=1
        break
    fi
done



if [[ $found -eq 1 ]]; then


  bestref=`echo ST$MLST`


  #mapping
  cat cat_reads_trimmed_q15_minlen5k_depth100_dechat_wgsim_R1.fastq cat_reads_trimmed_q15_minlen5k_depth100_dechat_wgsim_R2.fastq > cat_reads_trimmed_q15_minlen5k_depth100_dechat_wgsim_R12.fastq
  bwa index $reference_dir/$bestref".fasta"
  bwa bwasw -t 32 $reference_dir/$bestref".fasta" cat_reads_trimmed_q15_minlen5k_depth100_dechat_wgsim_R12.fastq > out12.sam
  samtools view -@ 32 -S -b out12.sam > out12.bam
  samtools sort -@ 32 out12.bam -o $1_$bestref"_out12.sorted.bam"
  samtools index $1_$bestref"_out12.sorted.bam"
  #splid bam
  samtools view -b  $1_$bestref"_out12.sorted.bam" NC_002695.2:1-250000 > $1_$bestref"_out12_1of22.sorted.bam"
  samtools view -b  $1_$bestref"_out12.sorted.bam" NC_002695.2:250001-500000 > $1_$bestref"_out12_2of22.sorted.bam"
  samtools view -b  $1_$bestref"_out12.sorted.bam" NC_002695.2:500001-750000 > $1_$bestref"_out12_3of22.sorted.bam"
  samtools view -b  $1_$bestref"_out12.sorted.bam" NC_002695.2:750001-1000000 > $1_$bestref"_out12_4of22.sorted.bam"
  samtools view -b  $1_$bestref"_out12.sorted.bam" NC_002695.2:1000001-1250000 > $1_$bestref"_out12_5of22.sorted.bam"
  samtools view -b  $1_$bestref"_out12.sorted.bam" NC_002695.2:1250001-1500000 > $1_$bestref"_out12_6of22.sorted.bam"
  samtools view -b  $1_$bestref"_out12.sorted.bam" NC_002695.2:1500001-1750000 > $1_$bestref"_out12_7of22.sorted.bam"
  samtools view -b  $1_$bestref"_out12.sorted.bam" NC_002695.2:1750001-2000000 > $1_$bestref"_out12_8of22.sorted.bam"
  samtools view -b  $1_$bestref"_out12.sorted.bam" NC_002695.2:2000001-2250000 > $1_$bestref"_out12_9of22.sorted.bam"
  samtools view -b  $1_$bestref"_out12.sorted.bam" NC_002695.2:2250001-2500000 > $1_$bestref"_out12_10of22.sorted.bam"
  samtools view -b  $1_$bestref"_out12.sorted.bam" NC_002695.2:2500001-2750000 > $1_$bestref"_out12_11of22.sorted.bam"
  samtools view -b  $1_$bestref"_out12.sorted.bam" NC_002695.2:2750001-3000000 > $1_$bestref"_out12_12of22.sorted.bam"
  samtools view -b  $1_$bestref"_out12.sorted.bam" NC_002695.2:3000001-3250000 > $1_$bestref"_out12_13of22.sorted.bam"
  samtools view -b  $1_$bestref"_out12.sorted.bam" NC_002695.2:3250001-3500000 > $1_$bestref"_out12_14of22.sorted.bam"
  samtools view -b  $1_$bestref"_out12.sorted.bam" NC_002695.2:3500001-3750000 > $1_$bestref"_out12_15of22.sorted.bam"
  samtools view -b  $1_$bestref"_out12.sorted.bam" NC_002695.2:3750001-4000000 > $1_$bestref"_out12_16of22.sorted.bam"
  samtools view -b  $1_$bestref"_out12.sorted.bam" NC_002695.2:4000001-4250000 > $1_$bestref"_out12_17of22.sorted.bam"
  samtools view -b  $1_$bestref"_out12.sorted.bam" NC_002695.2:4250001-4500000 > $1_$bestref"_out12_18of22.sorted.bam"
  samtools view -b  $1_$bestref"_out12.sorted.bam" NC_002695.2:4500001-4750000 > $1_$bestref"_out12_19of22.sorted.bam"
  samtools view -b  $1_$bestref"_out12.sorted.bam" NC_002695.2:4750001-5000000 > $1_$bestref"_out12_20of22.sorted.bam"
  samtools view -b  $1_$bestref"_out12.sorted.bam" NC_002695.2:5000001-5250000 > $1_$bestref"_out12_21of22.sorted.bam"
  samtools view -b  $1_$bestref"_out12.sorted.bam" NC_002695.2:5250001-5500000 > $1_$bestref"_out12_22of22.sorted.bam"

  samtools index $1_$bestref"_out12_1of22.sorted.bam"
  samtools index $1_$bestref"_out12_2of22.sorted.bam"
  samtools index $1_$bestref"_out12_3of22.sorted.bam"
  samtools index $1_$bestref"_out12_4of22.sorted.bam"
  samtools index $1_$bestref"_out12_5of22.sorted.bam"
  samtools index $1_$bestref"_out12_6of22.sorted.bam"
  samtools index $1_$bestref"_out12_7of22.sorted.bam"
  samtools index $1_$bestref"_out12_8of22.sorted.bam"
  samtools index $1_$bestref"_out12_9of22.sorted.bam"
  samtools index $1_$bestref"_out12_10of22.sorted.bam"
  samtools index $1_$bestref"_out12_11of22.sorted.bam"
  samtools index $1_$bestref"_out12_12of22.sorted.bam"
  samtools index $1_$bestref"_out12_13of22.sorted.bam"
  samtools index $1_$bestref"_out12_14of22.sorted.bam"
  samtools index $1_$bestref"_out12_15of22.sorted.bam"
  samtools index $1_$bestref"_out12_16of22.sorted.bam"
  samtools index $1_$bestref"_out12_17of22.sorted.bam"
  samtools index $1_$bestref"_out12_18of22.sorted.bam"
  samtools index $1_$bestref"_out12_19of22.sorted.bam"
  samtools index $1_$bestref"_out12_20of22.sorted.bam"
  samtools index $1_$bestref"_out12_21of22.sorted.bam"
  samtools index $1_$bestref"_out12_22of22.sorted.bam"



  #fimH typing with fimtyper database
  fimH_reference=`find $TOOLSPATH/fimtyper/fimtyper_db/fimH.fsa.split/ -maxdepth 1 -type f -name "*.fsa" ! -name ".*" -regextype posix-extended -regex ".*/fimH\.part_(00[1-9]|0[1-9][0-9]|100)\.fsa" | tr '\n' ',' | sed 's/,$//'`
  bbsplit.sh -Xmx20g ref=$fimH_reference in1=cat_reads_trimmed_q15_minlen5k_depth100_dechat_wgsim_R1.fastq in2=cat_reads_trimmed_q15_minlen5k_depth100_dechat_wgsim_R2.fastq outu1=clean1.fq.gz outu2=clean2.fq.gz refstats=refstats.out basename=out_%.fq.gz
  #%unambiguousReadsが最大の行を抜き出す
  bestref_fimH=`awk 'NR==1 {max=$2; max_line=$0} $2>max {max=$2; max_line=$0} END{print max_line}' refstats.out | awk '{print $1}'`




    #bamのコピーをreferenceごとに格納
    mkdir -p "$bam_dir" #$bam_dirというディレクトリがない場合は作成
    mkdir -p "$bam_dir/$bestref_fimH" #$bestrefというディレクトリがない場合は作成
    for i in {1..22}
    do
    cp $1_$bestref"_out12_"$i"of22.sorted.bam" $bam_dir/$bestref_fimH
    cp $1_$bestref"_out12_"$i"of22.sorted.bam.bai" $bam_dir/$bestref_fimH
    done

    #Making new a slinding dataset
    isolation_date=`grep $1 ../metadata.txt | awk '{print $2}'`

    if [ ! -f "$bam_dir/$bestref_fimH/dataset_before_sliding.txt" ]; then
      echo -e "id\tdate_str\tassigned_db" > $bam_dir/$bestref_fimH/dataset_before_sliding.txt
      echo -e "$1""\t""$isolation_date""\t""$bestref_fimH" >> $bam_dir/$bestref_fimH/dataset_before_sliding.txt
    else
      echo -e "$1""\t""$isolation_date""\t""$bestref_fimH" >> $bam_dir/$bestref_fimH/dataset_before_sliding.txt
    fi
    
    sliding_id=`python ~/program/TAROT_STEC_sliding_db_making_v1.4.py $1 36 $bam_dir/$bestref_fimH/dataset_before_sliding.txt`


    #bam_list, name_listを作成
    rm -f bam_list*
    for i in $sliding_id
    do

      for j in {1..22}
      do
         #bam_list
         find $bam_dir/$bestref_fimH -name "*sorted.bam" -type f | grep $i | grep "_"$j"of22" | uniq >> $output_dir_fullpath"/bam_list_"$j"of22.txt"
      done
      
      #name_listを作成
      find $bam_dir/$bestref_fimH -name "*sorted.bam" -type f | grep $i | sed 's|.*/||;s/\.sorted\.bam//' | sed 's/^/>/' | sed 's/_out12//' | awk -F "_" '{print $1}' | uniq >> $output_dir_fullpath"/name_list.txt"
    done

    #不要なファイルの削除
    rm *.sam out12.bam cat_reads_trimmed_q15_minlen5k_depth100_dechat_wgsim_R1.fastq cat_reads_trimmed_q15_minlen5k_depth100_dechat_wgsim_R2.fastq clean1.fq.gz clean2.fq.gz cat_reads.fastq cat_reads_trimmed_q15_minlen5k.fastq cat_reads_trimmed_q15_minlen5k_depth100.fastq cat_reads_trimmed_q15_minlen5k_depth100_dechat_wgsim_R12.fastq out_*.fq.gz out*.fq

    #.fastq圧縮
    pigz -f *.fastq


    ####菌株数が4株未満のとき、SNPs抽出は実行しない####
    # ファイルの行数をカウント
    linecount=$(wc -l < "$output_dir_fullpath/name_list.txt")

   if [ "$linecount" -ge 4 ]; then
     #SNPs抽出
     #移動
     cd $output_dir_fullpath
     #mpileupcns
     parallel -j 22 "samtools mpileup -B -f $reference_dir/$bestref".fasta" -b bam_list_{}of22.txt | java -jar $TOOLSPATH/VarScan.v2.3.9.jar mpileup2cns > mpileup2cns_{}of22.txt" ::: 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22
     #merge
     awk -F'\t' 'NR==1 || ($2 >= 1 && $2 <= 250000)' mpileup2cns_1of22.txt > mpileup2cns.txt
     awk -F'\t' '$2 >= 250001 && $2 <= 500000' mpileup2cns_2of22.txt >> mpileup2cns.txt
     awk -F'\t' '$2 >= 500001 && $2 <= 750000' mpileup2cns_3of22.txt >> mpileup2cns.txt
     awk -F'\t' '$2 >= 750001 && $2 <= 1000000' mpileup2cns_4of22.txt >> mpileup2cns.txt
     awk -F'\t' '$2 >= 1000001 && $2 <= 1250000' mpileup2cns_5of22.txt >> mpileup2cns.txt
     awk -F'\t' '$2 >= 1250001 && $2 <= 1500000' mpileup2cns_6of22.txt >> mpileup2cns.txt
     awk -F'\t' '$2 >= 1500001 && $2 <= 1750000' mpileup2cns_7of22.txt >> mpileup2cns.txt
     awk -F'\t' '$2 >= 1750001 && $2 <= 2000000' mpileup2cns_8of22.txt >> mpileup2cns.txt
     awk -F'\t' '$2 >= 2000001 && $2 <= 2250000' mpileup2cns_9of22.txt >> mpileup2cns.txt
     awk -F'\t' '$2 >= 2250001 && $2 <= 2500000' mpileup2cns_10of22.txt >> mpileup2cns.txt
     awk -F'\t' '$2 >= 2500001 && $2 <= 2750000' mpileup2cns_11of22.txt >> mpileup2cns.txt
     awk -F'\t' '$2 >= 2750001 && $2 <= 3000000' mpileup2cns_12of22.txt >> mpileup2cns.txt
     awk -F'\t' '$2 >= 3000001 && $2 <= 3250000' mpileup2cns_13of22.txt >> mpileup2cns.txt
     awk -F'\t' '$2 >= 3250001 && $2 <= 3500000' mpileup2cns_14of22.txt >> mpileup2cns.txt
     awk -F'\t' '$2 >= 3500001 && $2 <= 3750000' mpileup2cns_15of22.txt >> mpileup2cns.txt
     awk -F'\t' '$2 >= 3750001 && $2 <= 4000000' mpileup2cns_16of22.txt >> mpileup2cns.txt
     awk -F'\t' '$2 >= 4000001 && $2 <= 4250000' mpileup2cns_17of22.txt >> mpileup2cns.txt
     awk -F'\t' '$2 >= 4250001 && $2 <= 4500000' mpileup2cns_18of22.txt >> mpileup2cns.txt
     awk -F'\t' '$2 >= 4500001 && $2 <= 4750000' mpileup2cns_19of22.txt >> mpileup2cns.txt
     awk -F'\t' '$2 >= 4750001 && $2 <= 5000000' mpileup2cns_20of22.txt >> mpileup2cns.txt
     awk -F'\t' '$2 >= 5000001 && $2 <= 5250000' mpileup2cns_21of22.txt >> mpileup2cns.txt
     awk -F'\t' '$2 >= 5250001 && $2 <= 5500000' mpileup2cns_22of22.txt >> mpileup2cns.txt

     #コアゲノムmultifasta作成
     grep -v "N:" mpileup2cns.txt | grep -v "/" | grep "Pass" | perl -pe 's/\t/ /g' | cut -d " " -f 11-300 | perl -pe 's/:/ /g' | awk '{print $1,$7,$13,$19,$25,$31,$37,$43,$49,$55,$61,$67,$73,$79,$85,$91,$97,$103,$109,$115,$121,$127,$133,$139,$145,$151,$157,$163,$169,$175,$181,$187,$193,$199,$205,$211,$217,$223,$229,$235,$241,$247,$253,$259,$265,$271,$277,$283,$289,$295,$301,$307,$313,$319,$325,$331,$337,$343,$349,$355,$361,$367,$373,$379,$385,$391,$397,$403,$409,$415,$421,$427,$433,$439,$445,$451,$457,$463,$469,$475,$481,$487,$493,$499,$505,$511,$517,$523,$529,$535,$541,$547,$553,$559,$565,$571,$577,$583,$589,$595,$601,$607,$613,$619,$625,$631,$637,$643,$649,$655,$661,$667,$673,$679,$685,$691,$697,$703,$709,$715,$721,$727,$733,$739,$745,$751,$757,$763,$769,$775,$781,$787,$793,$799,$805,$811,$817,$823,$829,$835,$841,$847,$853,$859,$865,$871,$877,$883,$889}' | grep -v -e Q -e W -e R -e Y -e U -e I -e O -e P -e S -e D -e F -e H -e J -e K -e L -e Z -e X -e V -e B -e N -e M -e q -e w -e r -e y -e u -e i -e o -e p -e s -e d -e f -e h -e j -e k -e l -e z -e x -e v -e b -e n -e m | perl -pe 's/ /\t/g' | perl $TOOLSPATH/transpose1.pl | perl -pe 's/\t//g' > mpileup2cns_tran.txt
     paste name_list.txt mpileup2cns_tran.txt | perl -pe 's/\t/\n/g' > mpileup2cns_tran.fasta
     #ファイル変形 (originalの作成)
     grep -v "N:" mpileup2cns.txt | grep -v "/" | grep "Pass" | perl -pe 's/\t/ /g' | cut -d " " -f 11-300 | perl -pe 's/:/ /g' | awk '{print $1,$7,$13,$19,$25,$31,$37,$43,$49,$55,$61,$67,$73,$79,$85,$91,$97,$103,$109,$115,$121,$127,$133,$139,$145,$151,$157,$163,$169,$175,$181,$187,$193,$199,$205,$211,$217,$223,$229,$235,$241,$247,$253,$259,$265,$271,$277,$283,$289,$295,$301,$307,$313,$319,$325,$331,$337,$343,$349,$355,$361,$367,$373,$379,$385,$391,$397,$403,$409,$415,$421,$427,$433,$439,$445,$451,$457,$463,$469,$475,$481,$487,$493,$499,$505,$511,$517,$523,$529,$535,$541,$547,$553,$559,$565,$571,$577,$583,$589,$595,$601,$607,$613,$619,$625,$631,$637,$643,$649,$655,$661,$667,$673,$679,$685,$691,$697,$703,$709,$715,$721,$727,$733,$739,$745,$751,$757,$763,$769,$775,$781,$787,$793,$799,$805,$811,$817,$823,$829,$835,$841,$847,$853,$859,$865,$871,$877,$883,$889}' | grep -v -e Q -e W -e R -e Y -e U -e I -e O -e P -e S -e D -e F -e H -e J -e K -e L -e Z -e X -e V -e B -e N -e M -e q -e w -e r -e y -e u -e i -e o -e p -e s -e d -e f -e h -e j -e k -e l -e z -e x -e v -e b -e n -e m | perl -pe 's/ /\t/g' > mpileup2cns_original.txt
     #ファイル変形 (commonの作成, $1==$2,,,のところは菌株数に依存して変動)
     compare_strains=`grep ">" name_list.txt | wc -l`   #比較する菌株数に応じて、列数の記述をピックアップ 
     conpare_strains_object=`cat $TOOLSPATH/core_genome_SNPs_strain_number_database.txt | awk -F "\t" -v number="${compare_strains}" '$1==number {print $3}'`
     eval ${conpare_strains_object} #awk '$1==$2 && $1==$3.... {print $0}' mpileup2cns_original.txt > mpileup2cns_common.txt  ...のところに、菌株数相当の比較文が挿入される。300株まで対応。
     #originalとcommonを比較してsnp箇所だけ残す
     diff mpileup2cns_original.txt mpileup2cns_common.txt | grep "<" | cut -d" " -f "2-100" > mpileup2cns_nondupli.txt
     #snpのみのｍultifasta生成
     perl $TOOLSPATH/transpose1.pl mpileup2cns_nondupli.txt | perl -pe 's/\t//g' > mpileup2cns_nondupli_tran.txt
     paste name_list.txt mpileup2cns_nondupli_tran.txt | perl -pe 's/\t/\n/g' > mpileup2cns_nondupli_tran.fasta
     #fastaをphy形式に変換
     python $TOOLSPATH/convert_fasta_to_phylip.py -i mpileup2cns_nondupli_tran.fasta -o mpileup2cns_nondupli_tran.phy
     #phyml (ClonalFrameMLのstarting tree作成)
     phyml -i mpileup2cns_nondupli_tran.phy -m GTR -b 100
     #不要ファイルの削除と圧縮
     rm mpileup2cns_tran.txt mpileup2cns_original.txt mpileup2cns_common.txt mpileup2cns_nondupli.txt mpileup2cns_nondupli_tran.txt
     pigz mpileup2cns.txt mpileup2cns*of22.txt 
     #相同組換推定領域の検出 (ClonalFrameML)
     #kappa 計算
     AG=`grep "A <-> G" mpileup2cns_nondupli_tran.phy_phyml_stats.txt | awk '{print $4}'`
     CT=`grep "C <-> T" mpileup2cns_nondupli_tran.phy_phyml_stats.txt | awk '{print $4}'`
     AC=`grep "A <-> C" mpileup2cns_nondupli_tran.phy_phyml_stats.txt | awk '{print $4}'`
     AT=`grep "A <-> T" mpileup2cns_nondupli_tran.phy_phyml_stats.txt | awk '{print $4}'`
     CG=`grep "C <-> G" mpileup2cns_nondupli_tran.phy_phyml_stats.txt | awk '{print $4}'`
     GT=`grep "G <-> T" mpileup2cns_nondupli_tran.phy_phyml_stats.txt | awk '{print $4}'`
     kappa=`echo "scale=5; (($AG + $CT) / 2) /  (($AC + $AT + $CG + $GT) / 4)" | bc`
       
     #ClonalFrameMLの実行
     ClonalFrameML mpileup2cns_nondupli_tran.phy_phyml_tree.txt mpileup2cns_tran.fasta mpileup2cns_tran -kappa $kappa -emsim 100
     #相同組換領域の除外
     python $TOOLSPATH/remove_rec_from_ClonalFrameML_output_v1.1.py -a mpileup2cns_tran.fasta -o mpileup2cns_tran.importation_status.txt
     #SNPのみの配列に整形
     grep -v ">" mpileup2cns_tran.recRemoved.fasta | perl -pe 's/\n/_/g' | fold -1 | perl -pe 's/\n/\t/g' | perl -pe 's/\t_\t/\n/g' | perl $TOOLSPATH/transpose1.pl  | sed '$d' > mpileup2cns_tran.recRemoved.tran
        
     #commonの作成 #ファイル変形 (commonの作成, $1==$2,,,のところは菌株数に依存して変動)
     compare_strains_aftre_clonalframeml=`grep ">" name_list.txt | wc -l`   #比較する菌株数に応じて、列数の記述をピックアップ 
     conpare_strains_object_clonalframeml=`cat $TOOLSPATH/core_genome_SNPs_strain_number_database_after_clonalframeml.txt | awk -F "\t" -v number="${compare_strains}" '$1==number {print $3}'`
     eval ${conpare_strains_object_clonalframeml} #awk '$1==$2 && $1==$3.... {print $0}' mpileup2cns_original.txt > mpileup2cns_common.txt  ...のところに、菌株数相当の比較文が挿入される。300株まで対応。
     diff mpileup2cns_tran.recRemoved.tran mpileup2cns_tran.recRemoved.tran.common | grep "<" | cut -d " " -f 2-100 > mpileup2cns_tran.recRemoved.tran.common.snp
     perl $TOOLSPATH/transpose1.pl mpileup2cns_tran.recRemoved.tran.common.snp | perl -pe 's/\t//g' > mpileup2cns_tran.recRemoved.tran.common.snp.prefas
     paste name_list.txt mpileup2cns_tran.recRemoved.tran.common.snp.prefas | perl -pe 's/\t/\n/g' > mpileup2cns_tran.recRemoved.tran.common.snp.fasta
     rm mpileup2cns_tran.recRemoved.tran mpileup2cns_tran.recRemoved.tran.common mpileup2cns_tran.recRemoved.tran.common.snp mpileup2cns_tran.recRemoved.tran.common.snp.prefas
     #分子系統解析 (RAxML)
     rm -f *RAxML*
     raxmlHPC-PTHREADS -f a -s mpileup2cns_tran.recRemoved.tran.common.snp.fasta -n mpileup2cns_tran.recRemoved.tran.common.snp_RAxML -m GTRGAMMA -T 32 -x 12345 -p12345 -# 1000
     bash ~/program/run_plot_tree_v1.sh
     #SNPsのカウント
     snp-dists mpileup2cns_tran.recRemoved.tran.common.snp.fasta > mpileup2cns_tran.recRemoved.tran.common.snp_distance.tsv
   fi

fi

   
cd ..

rm -f clean1.fq clean2.fq recorrected.fa reads_k21_s1.h5 cat_reads_trimmed_q15_minlen5k_depth100_dechat.ec.fa 

