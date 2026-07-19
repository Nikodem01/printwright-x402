module OpenBooks
  class Snapshot
    RECENT_PROOF_LIMIT = 5

    def self.call = new.call

    def call
      hcs = hcs_snapshot
      local_anchored = real_licenses.where(hcs_topic_id: hcs[:topic_id]).where.not(hcs_sequence_number: nil).count
      {
        generated_at: Time.current.utc.iso8601,
        network: Hedera::Network.caip2,
        split: {
          designer_bps: 10_000 - LedgerEntry::PLATFORM_FEE_BPS,
          platform_bps: LedgerEntry::PLATFORM_FEE_BPS
        },
        hcs: hcs.merge(
          local_anchored_licenses: local_anchored,
          count_difference: hcs[:message_count] && hcs[:message_count] - local_anchored
        ),
        ledger: ledger_snapshot,
        recent_settlement_proofs: recent_settlement_proofs
      }
    end

    private

    def hcs_snapshot
      topic_id = ENV.fetch("HEDERA_HCS_TOPIC_ID", "0.0.9585069")
      raise Hedera::Network::Unavailable, "invalid topic id" unless topic_id.match?(/\A\d+\.\d+\.\d+\z/)

      Rails.cache.fetch([ "open-books-hcs", Hedera::Network.name, topic_id ], expires_in: 1.minute) do
        path = "/api/v1/topics/#{topic_id}/messages?limit=1&order=desc"
        response = Hedera::Network.get(path)
        raise Hedera::Network::Unavailable, "mirror HTTP #{response.code}" unless response.code.to_i == 200

        latest = JSON.parse(response.body).fetch("messages").first
        count = latest ? valid_latest_sequence(latest) : 0
        {
          status: "ok",
          topic_id: topic_id,
          message_count: count,
          latest_sequence_number: latest&.fetch("sequence_number"),
          latest_consensus_timestamp: latest&.fetch("consensus_timestamp"),
          mirror_url: "#{Hedera::Network.mirror_base}#{path}",
          latest_message_url: latest &&
            "#{Hedera::Network.mirror_base}/api/v1/topics/#{topic_id}/messages/#{latest.fetch('sequence_number')}",
          hashscan_url: "#{Hedera::Network.hashscan_base}/topic/#{topic_id}"
        }
      end
    rescue Hedera::Network::Unavailable, JSON::ParserError, KeyError, ArgumentError
      {
        status: "unavailable",
        topic_id: topic_id,
        message_count: nil,
        latest_sequence_number: nil,
        latest_consensus_timestamp: nil,
        mirror_url: nil,
        latest_message_url: nil,
        hashscan_url: "#{Hedera::Network.hashscan_base}/topic/#{topic_id}"
      }
    end

    def valid_latest_sequence(message)
      certificate = JSON.parse(Base64.strict_decode64(message.fetch("message")))
      sequence = Integer(message.fetch("sequence_number"))
      unless message.fetch("topic_id") == ENV.fetch("HEDERA_HCS_TOPIC_ID", "0.0.9585069") &&
          sequence.positive? && certificate["v"] == 1 && certificate["cert_id"].to_s.match?(/\Apw-\d{6,}\z/)
        raise ArgumentError, "latest message is not a PWC-1 certificate"
      end
      sequence
    end

    def ledger_snapshot
      totals = LedgerEntry.group(:asset, :entry_kind).sum(:amount_base_units)
      assets = totals.keys.map(&:first).uniq.sort.map do |asset|
        designer = totals.fetch([ asset, "designer_share" ], 0)
        platform = totals.fetch([ asset, "platform_fee" ], 0)
        refunds = totals.fetch([ asset, "refund" ], 0)
        {
          asset: asset,
          symbol: asset_symbol(asset),
          decimals: asset_decimals(asset),
          gross_settled_base_units: designer + platform,
          designer_share_base_units: designer,
          platform_fee_base_units: platform,
          refunded_base_units: refunds,
          net_after_refunds_base_units: designer + platform - refunds
        }
      end
      {
        settlement_count: LedgerEntry.where(entry_kind: "platform_fee").count,
        refund_count: LedgerEntry.where(entry_kind: "refund").count,
        assets: assets
      }
    end

    def recent_settlement_proofs
      LedgerEntry.where(entry_kind: "platform_fee").includes(:purchase)
        .order(created_at: :desc).limit(RECENT_PROOF_LIMIT).filter_map do |entry|
        tx_id = entry.purchase.payment_tx_id
        mirror_id = mirror_transaction_id(tx_id)
        next unless mirror_id

        {
          transaction_id: tx_id,
          asset: entry.asset,
          gross_base_units: gross_for(entry.purchase_id),
          mirror_url: "#{Hedera::Network.mirror_base}/api/v1/transactions/#{mirror_id}",
          hashscan_url: "#{Hedera::Network.hashscan_base}/transaction/#{tx_id}"
        }
      end
    end

    def gross_for(purchase_id)
      LedgerEntry.where(purchase_id: purchase_id, entry_kind: %w[designer_share platform_fee])
        .sum(:amount_base_units)
    end

    def mirror_transaction_id(tx_id)
      match = tx_id.to_s.match(/\A(\d+\.\d+\.\d+)@(\d+)\.(\d{1,9})\z/)
      "#{match[1]}-#{match[2]}-#{match[3]}" if match
    end

    def real_licenses
      License.joins(:purchase).where(purchases: { sandbox: false })
    end

    def asset_symbol(asset)
      return "HBAR" if asset == "0.0.0"
      return "USDC" if asset == Hedera::Network.usdc_asset
      asset
    end

    def asset_decimals(asset)
      return 8 if asset == "0.0.0"
      6 if asset == Hedera::Network.usdc_asset
    end
  end
end
