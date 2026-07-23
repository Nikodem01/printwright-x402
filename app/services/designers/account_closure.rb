module Designers
  # Prepares an irreversible account closure inside Rodauth's close-account
  # transaction. Nothing buyer-relevant is deleted: models with any purchase
  # history become retired, while listings with no purchase history are safe to
  # remove. Shared payout and offer locks close the last-sale/last-payout races.
  class AccountClosure
    class Error < StandardError
      attr_reader :code

      def initialize(code)
        @code = code
        super(code.to_s.humanize)
      end
    end

    IN_FLIGHT_PURCHASE_STATES = %w[pending verified settled].freeze

    def self.prepare!(designer)
      ActiveRecord::Base.connection.execute(
        "SELECT pg_advisory_xact_lock(#{Ledger::PayoutRunner::ADVISORY_LOCK_KEY})"
      )
      designer.lock!

      offers = LicenseOffer.joins(:model3d)
        .where(models3d: { designer_id: designer.id }).order(:id).lock.to_a
      models = designer.models3d.order(:id).lock.to_a

      raise Error, :outstanding_earnings if LedgerEntry.owed.where(designer: designer).exists?
      if Purchase.joins(license_offer: :model3d)
          .where(models3d: { designer_id: designer.id }, sandbox: false,
                 status: IN_FLIGHT_PURCHASE_STATES).exists?
        raise Error, :purchase_in_progress
      end

      purchase_model_ids = Purchase.where(license_offer_id: offers.map(&:id))
        .joins(:license_offer).distinct.pluck("license_offers.model3d_id")
      retained, removable = models.partition { |model| purchase_model_ids.include?(model.id) }

      retained.each do |model|
        model.update_columns(status: "retired", catalog_import_id: nil, updated_at: Time.current)
      end
      removable.each(&:destroy!)

      remove_private_integrations!(designer)
      designer.catalog_imports.destroy_all
      designer.profile_verifications.destroy_all
      designer.payout_attempts.destroy_all
    end

    def self.remove_private_integrations!(designer)
      endpoint_ids = designer.webhook_endpoints.order(:id).lock.pluck(:id)
      WebhookDelivery.where(webhook_endpoint_id: endpoint_ids).delete_all
      designer.webhook_endpoints.destroy_all
    end
    private_class_method :remove_private_integrations!
  end
end
