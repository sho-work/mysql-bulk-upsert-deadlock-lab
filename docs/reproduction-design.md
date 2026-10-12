# Bulk Upsert デッドロック：ローカル再現実験設計書

作成日：2026-10-12
状態：実験設計。DBを起動しての実行・再現確認は未実施。

## 1. 目的と到達点

添付の PhoneNumberUsage.import! と電話番号ごとのJSON履歴モデルを基に、並列Bulk Upsertのデッドロックを調査する。Repeatable Read（RR）とRead Committed（RC）で、同じ入力・DDL・実行条件を比較する。

成果は「エラー1213が出た」だけではなく、待機SQL、保持ロック、要求ロック、インデックス、循環待機の組を記録すること。ローカルで同じ機構を再現しても、当時のデッドロックログがなければ本番の原因の確定にはならない。

## 2. 添付から確認できること・不足すること

| 添付 | 確認した内容 | 未確認 |
|---|---|---|
| 20.54.50 | recordsを生成し、明示的なRCトランザクション内でimport!。更新対象は histories / updated_at、validate: false | recordsの型、SQL分割、件数、外側のトランザクション |
| 21.00.45 | 電話番号1件にJSON履歴、電話番号の完全一致検索 | 実テーブル名、型、暗号化方式、索引 |
| 18.34.58 | セカンダリ索引のX、PRIMARYのX,REC_NOT_GAPとsupremumのX | trx ID、取得済み/待機中、待機相手、SQL |
| 18.41.58 | 同一ギャップを保持するA/Bが相互の挿入を阻む仮説図 | Upsertだけで最初のギャップロックが生成されたか |

スライドは phone_numbers、コードは PhoneNumberUsage。以下では仮の実験テーブル名を phone_number_usages とする。idx_phone_xxxxx がUNIQUEかどうかはスクリーンショットだけでは確定できない。

supremumはインデックスページ上の疑似レコードである。画像だけから「テーブル全体の最大idの直後」と断定しない。ページや索引も含めて照合する。

## 3. 実験環境

Docker Compose等で独立したMySQLコンテナとRuby実行環境を用意する。実データは使わず、暗号化済み電話番号を模した文字列と合成JSONを使う。

- MySQL：本番Auroraの互換メジャーバージョンに対応するCommunity MySQL。タグとimage digestを固定。MariaDBで代用しない。
- Ruby / Rails（またはActiveRecord） / mysql2 / activerecord-import / concurrent-ruby：本番Gemfile.lockに合わせる。未入手なら採用バージョンを記録し、暫定実験とする。
- DB接続pool：ワーカー数以上。監視は別プロセス・別接続。ワーカーごとにwith_connectionで専用接続を使う。
- Performance Schema有効、innodb_deadlock_detect=ON、innodb_print_all_deadlocks=ON。error logを保存できる構成。
- 自動リトライは調査時は無効。1213（デッドロック）と1205（ロック待ちタイムアウト）を別集計。
- RR/RCは各トランザクションの開始時に指定。ネストしたトランザクションや既存トランザクション内で切り替えない。

起動後に保存する情報：

```sql
SELECT VERSION(), @@version_comment,
       @@transaction_isolation, @@autocommit,
       @@innodb_autoinc_lock_mode, @@innodb_deadlock_detect,
       @@innodb_lock_wait_timeout, @@binlog_format;
SHOW VARIABLES LIKE 'log_error';
SHOW VARIABLES LIKE 'performance_schema';
SET GLOBAL innodb_print_all_deadlocks = ON;
```

Aurora固有の実装・パッチとCommunity MySQLの差は残る。未再現を「本番でも起きない」と解釈しない。

## 4. 仮DDLと本番DDLの照合

最初に実環境から SHOW CREATE TABLE と SHOW INDEX を取得して照合する。暗号化カラムの型、照合順序、prefix索引、他のUNIQUE制約、外部キー、トリガーまで確認する。

以下は実験用の仮DDL。本番DDLの転記ではない。

```sql
CREATE DATABASE deadlock_lab;
USE deadlock_lab;
CREATE TABLE phone_number_usages (
  id BIGINT NOT NULL AUTO_INCREMENT,
  phone_number VARCHAR(255) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  histories JSON NOT NULL,
  created_at DATETIME(6) NOT NULL,
  updated_at DATETIME(6) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY idx_phone_xxxxx (phone_number)
) ENGINE=InnoDB;
```

電話番号のセカンダリUNIQUEを第一候補とするのは、Upsert時の電話番号重複による更新をモデル化するため。索引が非UNIQUEで他に一意制約がなければ、電話番号の重複だけではUPDATEに進まない。

比較DDLは別ケースとして保存する：①セカンダリUNIQUE＋自動採番PK、②電話番号をPKにする、③本番に追加索引・外部キーがあればその構成。複数要素を一度に変えない。

## 5. コードの再現範囲

添付の中心処理を維持する。CSV/S3/Sentryはデッドロック機構に直接必要でないため、最初はrecords生成を合成入力に置き換える。

```ruby
def import_records!(records, isolation:)
  PhoneNumberUsage.transaction(isolation: isolation) do
    PhoneNumberUsage.import!(
      records,
      on_duplicate_key_update: [:histories, :updated_at],
      validate: false
    )
  end
end
```

モデルは実験テーブルにマッピングし、JSONのシリアライズを実SQLと照合する。本番でidを指定しているならその条件も復元する。最初はrecordsをモデルインスタンス配列として実装し、実際のbuild_recordsの返却形式が判明したら合わせる。

各ワーカーはconnection_pool.with_connection内で、接続IDを取得し、開始ゲートで全ワーカーの準備を待ってからimportする。監視ログとconnection ID / run ID / worker IDを対応付ける。Concurrent::FixedThreadPoolを使う場合はワーカー例外を親に渡し、全タスクの終了を待つ。

sql.active_recordで実際のINSERT・BEGIN・COMMITとbindを採取する。gemのバージョンやmax_allowed_packet等によって、import!が1回でも複数SQLになる可能性を確認する。SQLを想像で書き換えず、採取したSQLをSQL単体実験にも使う。

## 6. 実験を3段階に分ける

### A. 単一ワーカーの基準確認

新規2件、既存2件の更新、新規と既存の混在をRR/RCで実行する。JSONとupdated_atが更新され、idとcreated_atが期待どおり保持されることを確認。トランザクションとSQL本数を記録する。

添付に近いロック観察を行う場合だけ、import後・commit前に外部ゲートで停止する。これは観察用の実行であり、停止なしの自然発生率測定と分ける。

### B. 添付コードに近い並列Bulk Upsert

追加のSELECT FOR UPDATE等を入れず、importだけを並列化する。

| ケース | ワーカー間のキー | 入力 | 調べること |
|---|---|---|---|
| B1 | 完全に別 | 新規のみ | 純粋な新規挿入で発生するか |
| B2 | 完全に別 | 既存のみ | 異なる電話番号への更新で発生するか |
| B3 | 完全に別 | 既存→新規を混在 | 添付の仮説に近い競合が生まれるか |
| B4 | 一部共有 | 既存キーを同じ順序 | 同一レコード競合の影響 |
| B5 | 一部共有 | 既存キーを逆順 | レコードロックの順序逆転 |
| B6 | 完全に別 | 空テーブルへの新規 | 空テーブル固有の影響 |

最初は2ワーカー、1SQLあたり2〜10行。再現しなければ100 / 1,000行、4 / 8ワーカーに拡張。実運用のファイル順序・キー分布・既存割合が判明したら優先して反映する。

各ケースをRR/RCで同じseed・初期データ・試行回数で比較する。目安は各100試行から開始。試行ごとに初期データを復元し、AUTO_INCREMENT値もそろえる。シャッフルは固定seed。「成功した1試行が次の試行の既存データになる」混同を防ぐ。

B5でデッドロックを起こしやすくするためSQLを2つに分けて同期させる実験は補助ケースとする。単一のBulk Upsertがその順で内部処理された証拠にはしない。

### C. 図のGap Lock循環待機を意図的に作る

これは仕組みの検証用。添付コードにはないロック読み取りを追加するため、Bとは独立して扱う。

初期データはid=13926の1行だけにする。A/B/監視の3接続を使い、以下の順番を手動またはゲート制御で実行する。

AとB、それぞれで：

```sql
USE deadlock_lab;
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;
START TRANSACTION;
SELECT id FROM phone_number_usages FORCE INDEX (PRIMARY)
WHERE id = 13927 FOR UPDATE;
```

両方のSELECTが完了したら監視接続で、両trxのPRIMARY supremumへの取得済みロックを確認する。期待するロックが見えなければ挿入に進まず、DDL・データ・実行計画を調べる。

Aで次を実行する。待機したら、監視でA→Bの待機を採取する。

```sql
INSERT INTO phone_number_usages
(id, phone_number, histories, created_at, updated_at)
VALUES (13927, 'enc_phone_AAA', JSON_ARRAY(), NOW(6), NOW(6));
```

続いてBで次を実行する：

```sql
INSERT INTO phone_number_usages
(id, phone_number, histories, created_at, updated_at)
VALUES (13928, 'enc_phone_BBB', JSON_ARRAY(), NOW(6), NOW(6));
```

期待：一方に1213、他方の挿入が進行する。直後にSHOW ENGINE INNODB STATUSとerror logを保存し、生存側をROLLBACKする。犠牲側もセッション状態を確認して終了する。

同じ初期状態からRCでも実行する。存在しない主キーの検索でのgap lockingが変わるため、この補助ケースでは両INSERTの進行を期待する。結果はログで判定する。

ここでのINSERTは異なるPK・電話番号を用いる。A/Bが通常のギャップロックを取得する起点を明示することが、この実験の役割である。

## 7. 観測SQLと採取タイミング

専用監視接続から取得する。ロックを保持中、最初の待機が成立した時点、エラー発生直後が重要。Bの負荷試験では100ms程度のポーリングを補助に使うが、短時間の循環は捕捉できないためerror logを主証拠とする。

```sql
SELECT ENGINE_LOCK_ID, ENGINE_TRANSACTION_ID, THREAD_ID,
       OBJECT_SCHEMA, OBJECT_NAME, INDEX_NAME,
       LOCK_TYPE, LOCK_MODE, LOCK_STATUS, LOCK_DATA
FROM performance_schema.data_locks
WHERE OBJECT_SCHEMA = 'deadlock_lab';

SELECT w.REQUESTING_ENGINE_TRANSACTION_ID AS waiting_trx,
       w.BLOCKING_ENGINE_TRANSACTION_ID AS blocking_trx,
       r.INDEX_NAME AS requested_index,
       r.LOCK_MODE AS requested_mode,
       r.LOCK_STATUS AS requested_status,
       r.LOCK_DATA AS requested_data,
       b.INDEX_NAME AS blocking_index,
       b.LOCK_MODE AS blocking_mode,
       b.LOCK_DATA AS blocking_data
FROM performance_schema.data_lock_waits w
JOIN performance_schema.data_locks r
  ON r.ENGINE = w.ENGINE
 AND r.ENGINE_LOCK_ID = w.REQUESTING_ENGINE_LOCK_ID
JOIN performance_schema.data_locks b
  ON b.ENGINE = w.ENGINE
 AND b.ENGINE_LOCK_ID = w.BLOCKING_ENGINE_LOCK_ID
WHERE r.OBJECT_SCHEMA = 'deadlock_lab';

SHOW ENGINE INNODB STATUS;
```

mysql CLIで縦表示する場合は最後のコマンドを SHOW ENGINE INNODB STATUS\G にする。APIから送るSQLには\Gを含めない。data_locks/data_lock_waitsは現在状態であり、別々の採取は原子的なスナップショットではない。

## 8. 判定基準

| 観測 | 言えること |
|---|---|
| ロック一覧にsupremum Xがあるだけ | そのロックが観測された。循環待機は未確認 |
| 一方向のwaitがある | ブロッキングは確認。デッドロックは未確認 |
| 1213＋ログに両trxの保持/要求がある | その試行のデッドロック機構を特定できる |
| 両側のinsert intention待機と相手のgap部分が対応 | 図の機構を支持する |
| PRIMARY/UNIQUEレコードの相互待ち | 別の機構として整理する |
| RCで0/100、RRで発生 | この条件ではRCで発生を観測しなかった |
| Cのみ成功、Bは未再現 | 図の機構は再現。本番相当Upsertの原因は未特定 |
| Bでも図と一致するログ | 添付コードに近い条件で同じ機構を再現。本番原因は当時の証拠次第 |

RCでも重複キー・外部キー検査にgap lockingが残るため、「RCはGap Lockが完全になくなる」「RCならデッドロックしない」とは説明しない。

## 9. 記録する成果物

各runに、環境バージョン、DDL、seed、初期件数、キー重複率、新規割合、バッチ件数、ワーカー数、分離レベル、SQL本数、接続ID、成功/1213/1205件数、実行時間を保存する。失敗runは生成SQL、入力キー順序、全デッドロックログ、直前のロック/待機情報を残す。

実装時の構成案：

- compose.yaml：MySQLとログ設定
- Gemfile / Gemfile.lock：依存固定
- schema.sql / seed.rb：仮DDL・本番相当DDL・固定seed
- runner.rb：Bの試行、開始ゲート、エラー分類
- controlled_gap.sql：Cの手順
- observe.sql：監視SQL
- results/<run_id>/：環境、SQL、ロック情報、error log、集計

まずA→B3→C→RR/RC比較の順で進める。Bで再現しない場合は、実DDL・gem生成SQL・データ重複・ファイル順序を確認してから負荷を増やす。

## 10. 参考資料

- MySQL 8.0：Locks Set by Different SQL Statements in InnoDB
  https://dev.mysql.com/doc/refman/8.0/en/innodb-locks-set.html
  UpsertでPRIMARY重複とUNIQUE重複のロックが異なる点を確認する。
- MySQL 8.0：InnoDB Locking
  https://dev.mysql.com/doc/refman/8.0/en/innodb-locking.html
  Gap Lock、Insert Intention、supremum、RCの例外を確認する。
- MySQL 8.0：An InnoDB Deadlock Example
  https://dev.mysql.com/doc/refman/8.0/en/innodb-deadlock-example.html
  ロック観測と全デッドロックのログ出力の手順。
- activerecord-import公式リポジトリ
  https://github.com/zdennis/activerecord-import
  導入バージョンのimport!、MySQL adapter、SQL分割を確認する。
