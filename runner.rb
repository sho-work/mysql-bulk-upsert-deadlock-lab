require_relative "lib/database"
require "time"

workers = Integer(ENV.fetch("WORKERS", "2"))
size = Integer(ENV.fetch("BATCH_SIZE", "10"))
trials = Integer(ENV.fetch("TRIALS", "100"))
scenario = ENV.fetch("CASE", "B3")
isolation = ENV.fetch("ISOLATION", "repeatable_read").to_sym
raise "positive sizes required" unless [workers, size, trials].all?(&:positive?)
raise "unknown CASE" unless %w[B1 B2 B3 B4 B5 B6].include?(scenario)
raise "unknown ISOLATION" unless %i[repeatable_read read_committed].include?(isolation)
Lab.connect!(workers)
run_id = "#{Time.now.utc.strftime('%Y%m%dT%H%M%S')}-#{Process.pid}-#{scenario}-#{isolation}"
dir = File.join("results", run_id)
FileUtils.mkdir_p(dir)
ActiveRecord::Base.logger = Logger.new(File.join(dir, "sql.log"))
main = ActiveRecord::Base.connection
metadata = {
  run_id: run_id, case: scenario, isolation: isolation, workers: workers,
  batch_size: size, trials: trials, ruby: RUBY_VERSION,
  gems: Gem.loaded_specs.transform_values { |g| g.version.to_s },
  database: main.select_one("SELECT VERSION() AS version, @@version_comment AS version_comment, @@innodb_autoinc_lock_mode AS autoinc_lock_mode, @@binlog_format AS binlog_format"),
  ddl: main.select_one("SHOW CREATE TABLE phone_number_usages")
}
File.write(File.join(dir, "environment.json"), JSON.pretty_generate(metadata))

counts = Hash.new(0)
File.open(File.join(dir, "trials.jsonl"), "w") do |output|
  trials.times do |trial|
    main.execute("TRUNCATE TABLE phone_number_usages")
    inputs = workers.times.map do |worker|
      keys = size.times.map do |i|
        if %w[B4 B5].include?(scenario)
          "enc_shared_#{i.to_s.rjust(8, '0')}"
        else
          "enc_w#{worker}_#{i.to_s.rjust(8, '0')}"
        end
      end
      scenario == "B5" && worker.odd? ? keys.reverse : keys
    end
    existing = case scenario
    when "B2", "B4", "B5" then inputs.flatten.uniq
    when "B3" then inputs.flat_map { |keys| keys.first((size + 1) / 2) }.uniq
    else []
    end
    timestamp = Time.utc(2026, 1, 1)
    unless existing.empty?
      PhoneNumberUsage.import!(
        existing.map { |key| PhoneNumberUsage.new(phone_number: key, histories: [], created_at: timestamp, updated_at: timestamp) },
        validate: false
      )
    end
    PhoneNumberUsage.columns # Load metadata before simultaneous execution.
    ready, start, outcomes = Queue.new, Queue.new, Queue.new
    threads = workers.times.map do |worker|
      Thread.new do
        signaled = false
        begin
          ActiveRecord::Base.connection_pool.with_connection do |conn|
            conn.execute("SET SESSION innodb_lock_wait_timeout = 5")
            connection_id = conn.select_value("SELECT CONNECTION_ID()")
            records = inputs[worker].map do |key|
              PhoneNumberUsage.new(phone_number: key,
                histories: [{ from: "2026-02", status: "01" }],
                created_at: timestamp, updated_at: timestamp + 1)
            end
            ready << worker
            signaled = true
            start.pop
            began = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            PhoneNumberUsage.transaction(isolation: isolation) do
              PhoneNumberUsage.import!(records,
                on_duplicate_key_update: [:histories, :updated_at], validate: false)
            end
            outcomes << { worker: worker, connection_id: connection_id, status: "success",
              elapsed: Process.clock_gettime(Process::CLOCK_MONOTONIC) - began }
          end
        rescue StandardError => error
          cause = error
          cause = cause.cause while cause.cause
          errno = cause.respond_to?(:error_number) ? cause.error_number : nil
          status = { 1213 => "deadlock", 1205 => "lock_timeout" }.fetch(errno, "error")
          outcomes << { worker: worker, status: status, errno: errno,
            error_class: error.class.name, message: error.message }
        ensure
          ready << worker unless signaled
        end
      end
    end
    workers.times { ready.pop }
    workers.times { start << true }
    threads.each(&:join)
    results = workers.times.map { outcomes.pop }
    results.each { |r| counts[r[:status]] += 1 }
    if results.all? { |r| r[:status] == "success" }
      expected_keys = inputs.flatten.uniq.sort
      rows = PhoneNumberUsage.order(:phone_number).to_a
      raise "final key set differs from inputs" unless rows.map(&:phone_number) == expected_keys
      expected_histories = [{ "from" => "2026-02", "status" => "01" }]
      raise "JSON upsert result differs" unless rows.all? { |r| r.histories == expected_histories }
      raise "created_at changed" unless rows.all? { |r| r.created_at == timestamp }
      raise "updated_at differs" unless rows.all? { |r| r.updated_at == timestamp + 1 }
    end
    output.puts(JSON.generate(trial: trial, keys: inputs, outcomes: results,
      final_rows: PhoneNumberUsage.count))
    output.flush
    if results.any? { |r| r[:status] != "success" }
      status = main.select_all("SHOW ENGINE INNODB STATUS").to_a
      File.write(File.join(dir, "trial-#{trial}-innodb.json"), JSON.pretty_generate(status))
    end
  end
end
File.write(File.join(dir, "summary.json"), JSON.pretty_generate(counts))
puts JSON.pretty_generate(run_id: run_id, counts: counts)
raise "unexpected worker error; see results" if counts["error"].positive?
