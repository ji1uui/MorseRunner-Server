# Teacher P1: 単局欧文・標準タイミングの生成

2026-09-23。schema 0.2のP1実装。既存のschema 0.1 CLIとGUIの音声経路は変更していません。

## 実装した範囲

- 単局欧文のクリーン音声、標準1:3:7、論理サンプル時計。初期文字集合はA–Z、0–9、`/.,?=`。
- 5～60換算WPM（小数3桁まで）、200～1200 Hz、振幅1～30000。
- UUID v4の全128ビットをBase32の26文字へ変換し、42文字の受信音声ファイル名を生成。
- ブロック単位の生成・保存と分割。分割を跨ぐ短点/長点・包絡線・搬送波を連続させる。
- 全体時刻に対応した符号・文字・メッセージ・局情報、manifest、SHA-256、検証結果。
- 独立CLIによるデータ検証、既存schema 0.1からの明示的な移行。
- 不正設定、未対応文字、既存出力先、過長パス、書込み失敗、中断、破損データの拒否。

和文、複合符号、途中変速、間隔拡張、無音だけの入力、バッチ、受信劣化、混信、GUI録音は後続フェーズです。単語間の空白は1個だけを許容し、前後空白や連続空白を黙って整形しません。legacy移行では元々許容されていた連続空白を保持します。

## ビルドと使用方法

Windows x64 / FPC 3.2.2 / PowerShell 7で確認しました。リポジトリルートで実行します。

```powershell
./tools/build_teacher.ps1
./lib/teacher/export_teacher.exe ./examples/teacher/cq.json ./lib/new-session
./lib/teacher/validate_dataset.exe ./lib/new-session
```

`new-session`は未作成のディレクトリを指定します。出力先の排他的作成に失敗した場合、既存データには書き込みません。検証に成功すると`VALID`と表示します。

設定例:

```json
{
  "schema_version":"0.2",
  "mode":"international",
  "timing_profile":"standard_v1",
  "text":"CQ CQ DE JI1UUI K",
  "wpm":20,
  "pitch_hz":700,
  "amplitude":12000,
  "chunk_seconds":60
}
```

全フィールド必須で、未知の設定項目も拒否します。入力設定はUTF-8 JSONです。P1では日本語等の非ASCII送信内容を拒否しますが、日本語の保存フォルダはWindowsで試験済みです。CLIはWindowsのUnicode引数を取得し、JSONやファイル処理と分離して文字化けによる誤受理を防ぎます。

| 制限 | P1の値 |
|---|---|
| 本文 | 1～65,536 ASCII文字 |
| 分割時間 | 1～3,600秒。通常は60秒 |
| 1セッションの音声ファイル数 | 最大16,000。manifestを読み込めるサイズに抑えるため、超過する設定は生成前に拒否 |
| パス長 | 生成する絶対パスと一時名を含め240文字以内という保守的なアプリ側制限。OS本来の上限を意味しない |
| JSONオブジェクトファイル | 最大16 MiB |
| 正常終了 | 0 |
| 不正な入力設定 | 2 |
| 生成・移行・保存エラー | 3 |
| データ検証不合格 | 4 |
| 引数の使用方法違反 | 64 |

FPCのみでのビルドでは`teacher`と`VCL`をunit検索パスに加え、`-Cr -Co`を有効にします。提供するビルドスクリプトはcommit/dirty情報を埋め込みます。手動ビルドでそれを省略した場合、source_commitはnullと理由付きで記録されます。

## 出力と音声の意味

受信音声名は `cw_<session_code>_r_<part>.wav`。内容は22,050 Hz、mono、PCM16 little-endianです。音声の一覧と全体時刻はmanifestから取得してください。

`symbols.jsonl`、`tokens.jsonl`、`stations.jsonl`、`messages.jsonl`、`conditions.jsonl`、`config.json`、`symbol_table.txt`、`validation.json`も保存します。P1には受信状態の変化がないためconditionsは空です。出力はUTF-8・BOMなし・LFです。

物理ラベルは0始まり、終端を含まない区間です。短点長は `22050 * 1200 / milli_wpm` サンプルを基準に、累積時刻を整数演算で丸めます。各短点を先に整数へ丸めて加算する方式ではありません。

標準モードは110サンプルのraised-cosine立上り/立下りを使います。立上りはkey-down時点、立下りはkey-up時点から始まるため、立下りの音は物理間隔の先頭に含まれます。文字間や語間を波形整形の長さだけ短縮しません。最後は3短点分のtrailing_gapを保存し、語間ラベルにしません。標準モードにバッファパディングはありません。

文字トークンはマークだけのevent_idsを参照し、範囲は最初のマーク開始から最後のマーク終了までです。メッセージのend_sampleは終了余白を含むラベル末尾を示します。

### 完了の確定と検証

生成後、イベント・トークン・局・メッセージ・設定を再読込し、宣言した設定からPCMを再構成して全バイトを照合します。その後validation.jsonとファイルハッシュを保存し、最後にmanifestの一時ファイルを正式名へrenameします。

完成manifestがない出力は、音声ファイルが存在していても学習へ投入できません。独立したvalidate_datasetも同じ契約検証を行い、元のファイルを書き換えません。検証器と生成器はタイミング/レンダリングコアを共有するため、試験側では別実装の時刻計算、固定符号表、波形の数式、標準ライブラリのハッシュで照合しています。

機械可読定義は [dataset.schema.json](../schemas/teacher/0.2/dataset.schema.json) の`$defs`と [config.schema.json](../schemas/teacher/0.2/config.schema.json)。スキーマだけでは検証できない時刻・参照・UUID表現・音声内容・ハッシュは検証CLIの対象です。条件変化や複数局を含む将来のプロファイルは、現行検証器が対応したことを確認してから投入してください。

## schema 0.1からの移行

```powershell
./lib/teacher/migrate_dataset.exe ./lib/old-session ./lib/migrated-session
./lib/teacher/validate_dataset.exe ./lib/migrated-session
```

元のmanifest、メッセージ、符号位置、PCMが現行schema 0.1のキーヤー出力と一致する場合だけ移行します。legacy波形・パディングを含むWAVの全バイトを維持し、短縮名とschema 0.2の関連ファイルを新しいディレクトリへ作成します。

timing_profileは`upstream_keyer_legacy`のままです。旧生成時のbuild情報は復元できないためunknownとし、元manifestとWAVのハッシュ、移行プログラムのbuild情報を区別して保存します。元データは変更しません。別のキーヤー版や別OSの浮動小数点差により厳密一致しないデータは移行を拒否します。

## 試験と実測

```powershell
./tests/test_teacher.ps1 -Python python
./tests/test_export.ps1
```

Python側は標準ライブラリのみを使用します。P1試験は範囲・オーバーフロー検査付きでビルドし、SHA-256既知値、UUID/Base32、8速度条件（17.321 WPMを含む）、累積時刻、41文字の符号表、波形端点、分割同一性、不正入力、日本語フォルダ、破損、競合、書込み失敗、中断、5速度での旧形式移行、1時間分生成を確認します。意図的な書込み失敗は専用の試験ビルドだけで有効です。

2026-09-23のWindows実測:

| 項目 | 結果 |
|---|---|
| P1統合試験 | 合格 |
| 旧試験（整数5～60 WPMのupstream波形一致を含む） | 合格 |
| Windows GUIビルド | 成功。既存のhint等は残存 |
| JSON Schema検証 | PowerShell Test-Jsonで設定、standard/legacyのmanifest、3セッションの計216オブジェクトを検証 |
| 1時間分の生成・内部検証・保存 | 14.742 秒、RTF 0.004095 |
| 観測ピークworking set | 11,665,408 bytes（約11.1 MiB、25 ms間隔でプロセス情報を取得） |
| 測定機 | Windows 10.0.26200、Intel Family 6 Model 170、18 logical processors |

測定はEを15,000文字、20 WPM、700 Hz、60秒分割で行いました。N150での測定ではなく、実時間入力の1時間耐久試験でもありません。性能値はこの条件の参考値です。測定対象binary SHA-256: `8a63655cba33eae9c350019a2e81ff5941d9f86654ac0e8c28d147d27aded3b8`。

試験証拠はgit対象外の`lib/teacher-*`と`lib/test-export-*`、性能記録は`lib/teacher/benchmark.json`に保存します。Windows以外のビルド、GUI実音再生、和文、実時間録音、学習モデルはNOT VERIFIEDです。

## 実装の対応

計画のTypes/Validation/Writerは、現段階では責務に沿ってTeacherContract / TeacherDataset / TeacherAudioへまとめました。Identity、Timing、Hash、Platformは独立unitです。GUIの共有Keyerに新しい記録処理を追加していません。

P2でschema 0.3の和文・複合符号・速度多様性・バッチを実装しました。[Teacher P2](teacher-p2.md)を参照してください。P1のschema 0.2と旧データは引き続き検証できます。
