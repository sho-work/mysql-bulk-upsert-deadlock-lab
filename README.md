# MySQL Bulk Upsert Deadlock Lab

電話番号ごとのJSON履歴を、ActiveRecord + activerecord-importで並列Upsertする実験用プロジェクト。

**状態：GitHub ActionsでDB実験を実行済み。RRの並列Bulk UpsertでPRIMARY supremumの循環待機を再現。** [実験結果](docs/results/2026-10-13.md)を参照。 本番DDL・Gemfile.lockは未入手のため、構成とバージョンは暫定です。依存は本番に合わせて更新してください。Aurora固有の挙動はCommunity MySQLと一致するとは限りません。

## 起動と実験

Docker Composeが必要です。この専用DBのデータは試行ごとにリセットされます。

```bash
docker compose build
docker compose up -d db
CASE=B3 ISOLATION=repeatable_read docker compose run --rm runner
CASE=B3 ISOLATION=read_committed docker compose run --rm runner
docker compose logs --no-color db > results/mysql-error.log
```

Gemfile.lockを初回ビルドから取り出してコミットし、以後DockerfileをGemfile.lockもCOPYする形に変更してください。現時点ではlock未生成のため推移依存は固定されていません。

```bash
docker compose run --rm runner cat Gemfile.lock > Gemfile.lock
```

| CASE | 条件 |
|---|---|
| B1 | 異なるキー、新規のみ |
| B2 | 異なるキー、既存のみ |
| B3 | 異なるキー、既存→新規の混在 |
| B4 | 全キー共有、同じ順序 |
| B5 | 全キー共有、奇数ワーカーは逆順 |
| B6 | 空テーブル、新規のみ（初期実装ではB1と同条件） |

WORKERS / BATCH_SIZE / TRIALSを環境変数で変更できます。例：

```bash
CASE=B3 WORKERS=4 BATCH_SIZE=100 TRIALS=100 ISOLATION=repeatable_read docker compose run --rm runner
```

SQLログ、入力キー、試行結果、実行環境はresults/<run_id>/に保存します。自動リトライは行いません。1213と1205を別集計します。エラー時のInnoDB Statusは試行終了後の取得で、直前のデッドロックを別試行や別DBのものと混同しないよう全error logと照合してください。

## ロックを観測

別ターミナルから接続し、sql/observe.sqlを実行します。

```bash
docker compose exec db mysql -uroot -plab-only-password deadlock_lab
```

図のギャップロック循環待機を意図的に作る実験は[設計書](docs/reproduction-design.md)のケースCを参照してください。追加のSELECT FOR UPDATEがあるため、Bulk Upsertだけの再現とは区別します。

## 最初の検証

1. TRIALS=1 / WORKERS=1でRRとRCを実行し、JSON更新とSQLを確認する。
2. B3をRR/RCで比較する。
3. ケースCを3接続で実行し、ロックと循環待機ログを採取する。
4. 再現ログから要求/保持ロックと索引を対応付ける。

RCで0件でも「RCならデッドロックしない」とは結論づけません。ローカルで再現できても本番原因の確定には当時のログが必要です。

## 参考

- https://dev.mysql.com/doc/refman/8.0/en/innodb-locking.html
- https://dev.mysql.com/doc/refman/8.0/en/innodb-locks-set.html
- https://github.com/zdennis/activerecord-import
