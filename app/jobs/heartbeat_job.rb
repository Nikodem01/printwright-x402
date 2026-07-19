class HeartbeatJob < ApplicationJob
  queue_as :default
  retry_on SidecarClient::Unavailable, wait: 5.minutes, attempts: 3

  def perform
    SidecarClient.new.submit_heartbeat(
      "schema" => "pwh-1",
      "service" => "printwright",
      "status" => "alive",
      "network" => Hedera::Network.caip2,
      "observed_at" => Time.current.utc.iso8601
    )
  end
end
