require "active_record"
require "activerecord-import"
require "json"
require "fileutils"
require "logger"

module Lab
  def self.connect!(workers)
    name = ENV.fetch("DB_NAME", "deadlock_lab")
    raise "This runner resets data; DB_NAME must be deadlock_lab" unless name == "deadlock_lab"
    ActiveRecord::Base.establish_connection(
      adapter: "mysql2", host: ENV.fetch("DB_HOST", "db"),
      database: name, username: ENV.fetch("DB_USER", "root"),
      password: ENV.fetch("DB_PASSWORD", "lab-only-password"),
      pool: workers + 2, checkout_timeout: 15
    )
    ActiveRecord::Base.connection.execute("SET SESSION innodb_lock_wait_timeout = 5")
  end
end

class PhoneNumberUsage < ActiveRecord::Base
  self.table_name = "phone_number_usages"
end
