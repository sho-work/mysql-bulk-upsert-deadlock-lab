require "mysql2"
require "json"
require "fileutils"
require "timeout"
require "time"

isolation = ENV.fetch("ISOLATION", "repeatable_read")
raise "unknown isolation" unless %w[repeatable_read read_committed].include?(isolation)
raise "DB_NAME must be deadlock_lab" unless ENV.fetch("DB_NAME", "deadlock_lab") == "deadlock_lab"
def connect
  Mysql2::Client.new(host: ENV.fetch("DB_HOST", "db"),
    username: ENV.fetch("DB_USER", "root"),
    password: ENV.fetch("DB_PASSWORD", "lab-only-password"),
    database: "deadlock_lab", symbolize_keys: true)
end
def snapshot(client)
  {
    locks: client.query("SELECT ENGINE_TRANSACTION_ID, THREAD_ID, INDEX_NAME, LOCK_MODE, LOCK_STATUS, LOCK_DATA FROM performance_schema.data_locks WHERE OBJECT_SCHEMA='deadlock_lab'").to_a,
    waits: client.query("SELECT * FROM performance_schema.data_lock_waits").to_a
  }
end
def insert(client, id, phone)
  client.query("INSERT INTO phone_number_usages (id, phone_number, histories, created_at, updated_at) VALUES (#{id}, '#{phone}', JSON_ARRAY(), NOW(6), NOW(6))")
  { status: "success" }
rescue Mysql2::Error => error
  { status: "error", errno: error.error_number, message: error.message }
end

dir = File.join("results", "controlled-#{Time.now.utc.strftime('%Y%m%dT%H%M%S')}-#{Process.pid}-#{isolation}")
FileUtils.mkdir_p(dir)
observer, a, b = Array.new(3) { connect }
thread = nil
report = { isolation: isolation }
begin
  observer.query("TRUNCATE TABLE phone_number_usages")
  insert(observer, 13926, "enc_seed")
  [a,b].each do |client|
    client.query("SET SESSION innodb_lock_wait_timeout=5")
    client.query("SET TRANSACTION ISOLATION LEVEL #{isolation.tr('_', ' ').upcase}")
    client.query("START TRANSACTION")
    client.query("SELECT id FROM phone_number_usages FORCE INDEX(PRIMARY) WHERE id > 13926 FOR UPDATE").to_a
  end
  report[:connections] = [a,b].map { |client| client.query("SELECT CONNECTION_ID() AS id").first[:id] }
  report[:before_insert] = snapshot(observer)
  if isolation == "repeatable_read"
    locks = report[:before_insert][:locks].select do |l|
      l[:INDEX_NAME] == "PRIMARY" && l[:LOCK_DATA] == "supremum pseudo-record" && l[:LOCK_STATUS] == "GRANTED"
    end
    raise "two supremum locks were not observed" unless locks.map { |l| l[:ENGINE_TRANSACTION_ID] }.uniq.size == 2
  end
  thread = Thread.new { insert(a, 13927, "enc_phone_AAA") }
  if isolation == "repeatable_read"
    Timeout.timeout(3) do
      loop do
        report[:first_wait] = snapshot(observer)
        break unless report[:first_wait][:waits].empty?
        sleep 0.02
      end
    end
  else
    thread.join
  end
  report[:b] = insert(b, 13928, "enc_phone_BBB")
  report[:a] = thread.value
  report[:innodb_status] = observer.query("SHOW ENGINE INNODB STATUS").to_a
  errors = [report[:a], report[:b]].filter_map { |r| r[:errno] }
  report[:expected_result] = isolation == "repeatable_read" ? errors == [1213] : errors.empty?
  File.write(File.join(dir, "report.json"), JSON.pretty_generate(report))
  puts JSON.pretty_generate(report.reject { |key,_| key == :innodb_status })
  raise "controlled experiment differed from expectation" unless report[:expected_result]
ensure
  thread.join(6) if thread
  [a,b].each do |client|
    begin
      client.query("ROLLBACK")
    rescue Mysql2::Error
      # Session may already have been rolled back by InnoDB.
    end
  end
  [observer,a,b].each(&:close)
end
