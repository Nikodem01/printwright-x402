require "test_helper"

class Backups::DatabaseDumpTest < ActiveSupport::TestCase
  FakeStatus = Struct.new(:success) do
    def success? = success
  end
  FakeConfig = Data.define(:database, :host, :configuration_hash)

  setup do
    set_printwright(backup_s3_bucket: "private-models", backup_s3_prefix: "database-backups")
  end

  teardown { restore_printwright }

  def stub_runner(contents: "PGDMP\x00private")
    runner = Object.new
    runner.define_singleton_method(:capture3) do |environment, *arguments|
      File.binwrite(arguments.fetch(arguments.index("--file") + 1), contents)
      @environment = environment
      @arguments = arguments
      [ "", "", FakeStatus.new(true) ]
    end
    runner
  end

  def stub_clock(time)
    clock = Object.new
    clock.define_singleton_method(:now) { time }
    clock
  end

  def fake_database_config
    FakeConfig.new("printwright_production", "db.internal",
                   { port: 5432, username: "app", password: "not-in-argv" })
  end

  # --- disk backend: for deployments with no object-storage provider ---

  test "disk backend writes an owner-only dump and needs no S3 credentials" do
    Dir.mktmpdir do |root|
      set_printwright(backup_backend: "disk", backup_disk_root: root, backup_disk_keep: 7)

      path = Backups::DatabaseDump.new(
        client: :must_not_be_used, runner: stub_runner,
        clock: stub_clock(Time.utc(2026, 7, 19, 12, 30, 45)),
        database_config: fake_database_config
      ).call

      assert_equal File.join(root, "printwright-20260719T123045Z.dump"), path
      assert_equal "PGDMP\x00private", File.binread(path)
      assert_equal "600", format("%o", File.stat(path).mode & 0o777),
        "a database dump must not be world-readable"
    end
  end

  test "disk backend creates the directory when it does not exist yet" do
    Dir.mktmpdir do |parent|
      root = File.join(parent, "nested", "database-backups")
      set_printwright(backup_backend: "disk", backup_disk_root: root, backup_disk_keep: 7)

      Backups::DatabaseDump.new(
        client: nil, runner: stub_runner, clock: stub_clock(Time.utc(2026, 1, 1)),
        database_config: fake_database_config
      ).call

      assert_predicate Pathname.new(root), :directory?
    end
  end

  # The whole point of the disk backend's retention: unbounded dumps on a capped
  # volume become the outage they exist to prevent.
  test "disk backend prunes to the retention count, keeping the newest" do
    Dir.mktmpdir do |root|
      set_printwright(backup_backend: "disk", backup_disk_root: root, backup_disk_keep: 2)

      %w[20260101T000000Z 20260102T000000Z 20260103T000000Z].each do |stamp|
        File.binwrite(File.join(root, "printwright-#{stamp}.dump"), "old")
      end

      Backups::DatabaseDump.new(
        client: nil, runner: stub_runner,
        clock: stub_clock(Time.utc(2026, 1, 4)), database_config: fake_database_config
      ).call

      remaining = Dir.children(root).sort
      assert_equal %w[printwright-20260103T000000Z.dump printwright-20260104T000000Z.dump],
        remaining
    end
  end

  test "disk backend leaves unrelated files in the directory alone" do
    Dir.mktmpdir do |root|
      set_printwright(backup_backend: "disk", backup_disk_root: root, backup_disk_keep: 1)
      File.write(File.join(root, "README.txt"), "not a dump")

      Backups::DatabaseDump.new(
        client: nil, runner: stub_runner,
        clock: stub_clock(Time.utc(2026, 1, 4)), database_config: fake_database_config
      ).call

      assert_includes Dir.children(root), "README.txt"
    end
  end

  test "a retention of zero is clamped to one, so a backup cannot delete itself" do
    assert_equal 1, PrintwrightSettings.normalize!(
      ActiveSupport::OrderedOptions.new.merge(backup_disk_keep: "0")
    ).backup_disk_keep
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
    set_printwright(backup_s3_prefix: "../outside")
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
