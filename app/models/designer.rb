class Designer < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :models3d, class_name: "Model3d", dependent: :destroy

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  validates :display_name, presence: true
end
