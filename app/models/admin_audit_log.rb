class AdminAuditLog < ApplicationRecord
  belongs_to :actor_designer, class_name: "Designer", optional: true

  validates :action, presence: true

  def readonly? = persisted?
end
