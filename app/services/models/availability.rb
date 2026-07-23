module Models
  class Availability
    InvalidTransition = Class.new(StandardError)

    TRANSITIONS = {
      pause: { from: %w[published], to: "paused" },
      resume: { from: %w[paused], to: "published" },
      retire: { from: %w[published paused], to: "retired" },
      restore: { from: %w[retired], to: "paused" }
    }.freeze

    def self.call(model:, action:)
      transition = TRANSITIONS.fetch(action.to_sym)
      Model3d.transaction do
        # Purchase reservation locks active offers. Taking the same locks in
        # id order makes a lifecycle change and a new reservation serialize.
        model.license_offers.reorder(:id).lock.load
        model.lock!
        unless transition.fetch(:from).include?(model.status)
          raise InvalidTransition, "cannot #{action} a #{model.status} listing"
        end
        if action.to_sym == :resume && model.license_offers.empty?
          raise InvalidTransition, "cannot resume without an active license offer"
        end

        model.update!(status: transition.fetch(:to))
      end
      model
    rescue KeyError
      raise InvalidTransition, "unknown listing availability action"
    end
  end
end
