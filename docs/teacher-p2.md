# Teacher P2: 欧文・和文のクリーン音声データ

2026-09-24。対象はWindows x64 / Lazarus 4.6 / FPC 3.2.2 / PowerShell 7。P1のschema 0.2と旧schema 0.1を保持し、P2の新規出力はschema 0.3とする。

## 使い方

リポジトリルートで実行する。出力先は未作成のディレクトリにする。

```powershell
./tools/build_teacher.ps1
./lib/teacher/export_teacher.exe ./examples/teacher/wabun-p2.json ./lib/wabun-session
./lib/teacher/validate_dataset.exe ./lib/wabun-session
```

バッチは確認済みコーパスから30条件の計画を作り、検証後に索引を確定する。

```powershell
python ./tools/prepare_teacher_plan.py ./examples/teacher/corpus-p2.json ./lib/teacher/plan.json
./tools/export_teacher_batch.ps1 -Plan ./lib/teacher/plan.json -OutputRoot ./lib/teacher-batch
./tools/validate_teacher_batch.ps1 -DatasetRoot ./lib/teacher-batch
```

中断時は同じ計画ファイルと保存先を指定して`-Resume`を付ける。完了済みセッションは検証して再利用する。途中まで書かれたセッションは自動的に正解扱いせず、その番号を報告して停止する。計画または既存設定が変化した場合も停止する。

## 符号と原文の扱い

欧文は[ITU-R M.1677-1](https://www.itu.int/dms_pubrec/itu-r/rec/m/R-REC-M.1677-1-200910-I!!PDF-E.pdf)の英字・数字・記号を採用する。和文は[無線局運用規則別表第一号](https://laws.e-gov.go.jp/law/325M50080000017?occasion_date=20260331)の2026-03-24改正施行版を採用し、[JARLの符号表](https://www.jarl.org/Japanese/A_Shiryo/A-C_Morse/morse.htm)とも照合した。manifestの`symbol_table_source`で採用版を固定し、`symbol_table.txt`のSHA-256も記録する。同じ物理符号に複数の候補がある場合も、受信側の候補を一つへ決め打ちしない。

`mode`は`international`、`wabun`、`mixed`。mixedは欧文から始まり、`{DO}`（ホレを続け打ち）で和文、`{SN}`（ラタを続け打ち）で欧文へ切り替える。これらの切替は[A1 CLUBの和文練習資料](https://a1club.org/CQ/5-Homebrew.pdf)に記載された運用例として扱う。切替符号自体も音声・1送信トークンとして記録する。`{AR}`、`{SK}`、`{BT}`、`{AS}`、`{HH}`も1トークンで、構成文字の間に文字間隔を入れない。`{RAW:--------}`のような8要素以内の未割当試験符号は`undefined`と明記し、割当済みの符号列は拒否する。モード切替や複合符号の意味解釈は後段のアプリの責務である。

和文入力では、ひらがなをカタカナに、小書き仮名を対応する大書き仮名に正規化する。ガ・パ等の濁音/半濁音は基底仮名と独立した濁点/半濁点の送信トークンへ分解し、同じ`source_token_index`に結び付ける。結合濁点も直前の仮名と同じ原文位置にする。全角数字と漢数字（一～九、〇）は数字符号に正規化する。`source_text`には元の表記、`emitted_text`には送信トークン表記を保存する。各トークンにはモード、符号列、物理イベント参照と原文位置がある。未対応文字、壊れたUTF-8、未許可の切替を黙って除去しない。

和文の`、`は区切点、`。`は段落の別符号。`「」`を上向/下向括弧として扱う。ASCIIの1個の空白だけを7短点の語間として送る。和文の分かち書きを生成器で自動挿入しない。

## 速度と波形

`wpm`と`wpm_end`はPARIS基準の換算WPMであり、和文の文字/分とは異なる。いずれも5～60、0.001 WPM単位。送信トークンの順序に沿って線形補間し、トークン内は一定速度とする。`gap_scale_milli`は文字間・語間だけに1.000～3.000倍を適用する。`jitter_milli`は各イベント長を0～±10%で変動させる。乱数は`seed`を持つ版管理された`xorshift32_v1`で、セッションUUIDとは独立する。同一設定・seedならUUIDとファイル名を除いたPCM・物理時刻・正解内容が一致する。

変速・揺らぎがない設定では、累積理想位置を整数サンプルへ丸めるP1の標準タイミングをそのまま使う。変速時は各イベント長を整数マイクロサンプルで積算してからサンプル位置へ丸める。`symbols.jsonl`が実際の各区間を記録する。5～60の全範囲で立上り・立下りは110サンプル、音声は22,050 Hz / mono / PCM16。分割境界をまたいでも搬送波位相と包絡線は連続する。

## バッチの索引と分割

計画は`teacher-batch-1`のJSONで、各itemに`group_id`、`split`（train/validation/test）、schema 0.3の`config`を指定する。出力先に計画を`plan.json`として保存し、各セッションを検証してから最後に`index.json`を確定する。索引にはセッションID、原文・設定・manifest・WAV・分割方法に依存しない連結PCMのハッシュ、サンプル数、送信トークン数を残す。検証器は全セッションを再検証し、索引の参照・ハッシュを照合する。同じ原文グループ、同じ原文、同一PCM音声が複数の分割へ入る場合は拒否する。

`prepare_teacher_plan.py`は欧文/和文×速度5帯×音程3帯の30セルに同数のセッションを配る。音声時間・トークン数の違いはバッチ検証レポートで示す。付属の4件コーパスによる30件出力は機能スモークであり、復号精度を主張できる学習集合ではない。学習前に文面・交信形式・受信条件を拡充し、独立した実受信試験集合を用意する。

パイプラインの規模試験には、版管理された乱数で合成文面200グループを作る。これは実受信や人手確認済みの文章ではない。

```powershell
python ./tools/make_teacher_trial_corpus.py ./lib/teacher/trial-corpus.json
python ./tools/prepare_teacher_plan.py ./lib/teacher/trial-corpus.json ./lib/teacher/trial-plan.json --repetitions 10
./tools/export_teacher_batch.ps1 -Plan ./lib/teacher/trial-plan.json -OutputRoot ./lib/teacher-trial-300
./tools/validate_teacher_batch.ps1 -DatasetRoot ./lib/teacher-trial-300
```

2026-09-24の試行では300セッション・30セルを生成・再検証し、各セル10件、原文グループ200件、train/validation/testは250/21/29件だった。セル別送信トークンは128～219、音声時間は43.53～473.56秒で、件数を揃えても音声量が偏ることが分かった。学習時の重み付けや窓数の設計にこの偏りを使う。

## 検証と範囲

```powershell
./tests/test_teacher.ps1 -Python python
./tests/test_teacher_p2.ps1 -Python python
./tests/test_export.ps1
./tests/bench_teacher_p2.ps1
```

P2試験は和文48仮名、全濁音・半濁音、数字・句読点、欧文49符号、複合符号、未知試験符号、原文位置、独立計算による変速・揺らぎ、同一seedのPCM一致、30セル、原文と分割方法の異なる同一PCMの漏洩拒否、再開を対象とする。WindowsのGUIビルドとP1/P0の回帰も確認する。

1時間分（実際は3600.467秒）のオフライン和文・揺らぎあり生成で、14.825秒、RTF 0.00412、観測ピークworking set 12,316,672 bytes（約11.75 MiB）だった。これは2026-09-24のWindows開発PC（Intel Family 6 Model 170、18 logical processors）での参考値。測定バイナリSHA-256は`9ccd5a62e555d58045ecb88aefa2ec563af228278bdc67f08405a97faa4be583`。N150実機と実時間入力の耐久試験ではない。詳細記録は`lib/teacher/p2-benchmark.json`。

受信劣化・複数局・GUI録音はP3、学習モデルと精度評価はP4、アプリ推論UIはP5。Windows以外は開発対象外である。
