require "aws-sdk-s3"
require "open3"
require "tempfile"

module Backups
  class DatabaseDump
    Error = Class.new(StandardError)

    def initialize(client: nil, runner: Open3, clock: Time, database_config: nil)
      @client = client
      @runner = runner
      @clock = clock
      @database_config = database_config
    end

    def call
      Tempfile.create([ "printwright-primary-", ".dump" ], binmode: true) do |file|
        dump!(file.path)
        disk_backend? ? store_on_disk!(file) : upload!(file)
      end
    end

    private

    attr_reader :runner, :clock

    def disk_backend? = config.backup_backend.to_s == "disk"

    # Writes owner-only, then prunes to the retention count. Pruning is the
    # point: an unbounded backup directory on a shared volume eventually takes
    # down everything else on the disk, which is a worse outage than the one
    # backups exist to prevent.
    #
    # This is not durability — the dump sits on the same disk as the database it
    # came from. See the runbook for the one command that pulls it off-box.
    def store_on_disk!(file)
      root = Pathname.new(config.backup_disk_root.to_s)
      raise Error, "BACKUP_DISK_ROOT is not set" if root.to_s.blank?

      root.mkpath
      destination = root.join(dump_filename)
      file.rewind
      destination.open("wb", 0o600) { |out| IO.copy_stream(file, out) }
      prune!(root)
      destination.to_s
    rescue SystemCallError => error
      raise Error, "backup write failed: #{error.class.name}"
    end

    def prune!(root)
      dumps = root.glob("printwright-*.dump").sort_by { |path| path.basename.to_s }
      dumps[0...-config.backup_disk_keep].to_a.each(&:delete)
    end

    def dump!(path)
      _stdout, stderr, status = runner.capture3(
        postgres_environment,
        "pg_dump", "--format=custom", "--no-owner", "--no-privileges",
        "--file", path, database_config.database.to_s
      )
      return if status.success?

      raise Error, "pg_dump failed: #{stderr.to_s.strip.first(500)}"
    end

    def upload!(file)
      file.rewind
      client.put_object(
        bucket: bucket,
        key: object_key,
        body: file,
        content_type: "application/vnd.postgresql.custom-dump",
        server_side_encryption: "AES256"
      )
      object_key
    rescue Aws::S3::Errors::ServiceError => error
      raise Error, "backup upload failed: #{error.class.name}"
    end

    # Timestamped so the name sorts chronologically — which is what makes disk
    # pruning a plain sort rather than a stat of every file.
    def dump_filename
      @dump_filename ||= "printwright-#{clock.now.utc.strftime('%Y%m%dT%H%M%SZ')}.dump"
    end

    def object_key
      @object_key ||= begin
        prefix = config.backup_s3_prefix.to_s.delete_prefix("/").delete_suffix("/")
        raise Error, "BACKUP_S3_PREFIX is invalid" if prefix.blank? || prefix.include?("..")

        "#{prefix}/#{dump_filename}"
      end
    end

    def bucket
      config.backup_s3_bucket!
    end

    def config
      Rails.configuration.x.printwright
    end

    def client
      @client ||= Aws::S3::Client.new(s3_options)
    end

    def s3_options
      {
        endpoint: config.s3_endpoint,
        region: config.s3_region,
        access_key_id: config.s3_access_key_id!,
        secret_access_key: config.s3_secret_access_key!,
        force_path_style: config.s3_force_path_style
      }.compact
    end

    def database_config
      @database_config ||= ActiveRecord::Base.configurations.configs_for(
        env_name: Rails.env, name: "primary"
      )
    end

    def postgres_environment
      {
        "PGHOST" => database_config.host,
        "PGPORT" => database_config.configuration_hash[:port]&.to_s,
        "PGUSER" => database_config.configuration_hash[:username],
        "PGPASSWORD" => database_config.configuration_hash[:password]
      }.compact
    end
  end
end
