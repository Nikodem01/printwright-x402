require "test_helper"

class Backups::DatabaseDumpTest < ActiveSupport::TestCase
  FakeStatus = Struct.new(:success) do
    def success? = success
  end
  FakeConfig = Data.define(:database, :host, :configuration_hash)

  setup do
    @env_was = %w[BACKUP_S3_BUCKET BACKUP_S3_PREFIX S3_BUCKET].index_with { |name| ENV[name] }
    ENV["S3_BUCKET"] = "private-models"
    ENV["BACKUP_S3_PREFIX"] = "database-backups"
  end

  teardown do
    @env_was.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end

  test "creates a custom dump without putting the password in argv and uploads it encrypted" do
    runner = Object.new
    runner.define_singleton_method(:capture3) do |environment, *arguments|
      path = arguments.fetch(arguments.index("--file") + 1)
      File.binwrite(path, "PGDMP\x00private")
      @environment = environment
      @arguments = arguments
      [ "", "", FakeStatus.new(true) ]
    end
    client = Object.new
    client.define_singleton_method(:put_object) do |options|
      @options = options.except(:body).merge(body: options.fetch(:body).read)
    end
    clock = Object.new
    clock.define_singleton_method(:now) { Time.utc(2026, 7, 19, 12, 30, 45) }
    config = FakeConfig.new(
      "printwright_production", "db.internal",
      { port: 5432, username: "app", password: "not-in-argv" }
    )

    key = Backups::DatabaseDump.new(
      client: client, runner: runner, clock: clock, database_config: config
    ).call

    assert_equal "database-backups/printwright-20260719T123045Z.dump", key
    assert_equal "not-in-argv", runner.instance_variable_get(:@environment)["PGPASSWORD"]
    assert_not_includes runner.instance_variable_get(:@arguments).join(" "), "not-in-argv"
    upload = client.instance_variable_get(:@options)
    assert_equal "private-models", upload[:bucket]
    assert_equal "AES256", upload[:server_side_encryption]
    assert_equal "PGDMP\x00private", upload[:body]
  end

  test "refuses a traversal backup prefix before uploading" do
    ENV["BACKUP_S3_PREFIX"] = "../outside"
    runner = Object.new
    runner.define_singleton_method(:capture3) do |_environment, *arguments|
      File.binwrite(arguments.fetch(arguments.index("--file") + 1), "PGDMP")
      [ "", "", FakeStatus.new(true) ]
    end

    error = assert_raises(Backups::DatabaseDump::Error) do
      Backups::DatabaseDump.new(
        client: Object.new, runner: runner,
        database_config: FakeConfig.new("db", nil, {})
      ).call
    end
    assert_equal "BACKUP_S3_PREFIX is invalid", error.message
  end

  test "does not upload a failed dump" do
    runner = Object.new
    runner.define_singleton_method(:capture3) { |_environment, *_arguments| [ "", "no space", FakeStatus.new(false) ] }

    error = assert_raises(Backups::DatabaseDump::Error) do
      Backups::DatabaseDump.new(
        client: Object.new, runner: runner,
        database_config: FakeConfig.new("db", nil, {})
      ).call
    end
    assert_equal "pg_dump failed: no space", error.message
  end
end
