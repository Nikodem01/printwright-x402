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
        upload!(file)
      end
    end

    private

    attr_reader :runner, :clock

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

    def object_key
      @object_key ||= begin
        prefix = ENV.fetch("BACKUP_S3_PREFIX", "database-backups").delete_prefix("/").delete_suffix("/")
        raise Error, "BACKUP_S3_PREFIX is invalid" if prefix.blank? || prefix.include?("..")

        "#{prefix}/printwright-#{clock.now.utc.strftime('%Y%m%dT%H%M%SZ')}.dump"
      end
    end

    def bucket
      ENV["BACKUP_S3_BUCKET"].presence || ENV.fetch("S3_BUCKET")
    end

    def client
      @client ||= Aws::S3::Client.new(s3_options)
    end

    def s3_options
      {
        endpoint: ENV["S3_ENDPOINT"].presence,
        region: ENV.fetch("S3_REGION", "us-east-1"),
        access_key_id: ENV.fetch("S3_ACCESS_KEY_ID"),
        secret_access_key: ENV.fetch("S3_SECRET_ACCESS_KEY"),
        force_path_style: ENV.fetch("S3_FORCE_PATH_STYLE", "false") == "true"
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
