module Webhooks
  module SecretBox
    def self.encrypt(secret)
      encryptor.encrypt_and_sign(secret, purpose: "webhook-secret")
    end

    def self.decrypt(ciphertext)
      encryptor.decrypt_and_verify(ciphertext, purpose: "webhook-secret")
    end

    def self.encryptor
      key = ActiveSupport::KeyGenerator.new(Rails.application.secret_key_base)
        .generate_key("printwright-webhooks-v1", 32)
      ActiveSupport::MessageEncryptor.new(key, cipher: "aes-256-gcm")
    end
    private_class_method :encryptor
  end
end
