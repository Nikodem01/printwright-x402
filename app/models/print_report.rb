class PrintReport < ApplicationRecord
  belongs_to :license

  validate :license_came_from_paid_delivery

  private

  def license_came_from_paid_delivery
    return if license&.purchase&.delivered? && !license.purchase.sandbox?

    errors.add(:license, "must come from a paid delivered purchase")
  end
end
