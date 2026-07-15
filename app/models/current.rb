class Current < ActiveSupport::CurrentAttributes
  attribute :session
  delegate :designer, to: :session, allow_nil: true
end
