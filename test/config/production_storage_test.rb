require "test_helper"
require "active_storage/service/s3_service"

class ProductionStorageTest < ActiveSupport::TestCase
  test "private S3 service URL carries the bounded production expiry" do
    service = ActiveStorage::Service::S3Service.new(
      bucket: "private-models",
      access_key_id: "test-access",
      secret_access_key: "test-secret",
      region: "us-east-1",
      endpoint: "https://s3.example.test",
      force_path_style: true,
      stub_responses: true
    )

    url = service.url(
      "private/model.stl", expires_in: 10.minutes,
      disposition: :attachment, filename: ActiveStorage::Filename.new("model.stl"),
      content_type: "model/stl"
    )
    query = Rack::Utils.parse_nested_query(URI(url).query)

    assert_equal "600", query.fetch("X-Amz-Expires")
    assert_equal "private-models", URI(url).path.split("/").second
  end
end
