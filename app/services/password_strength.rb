# Password policy beyond length (S1): reject low-entropy passwords (zxcvbn) and
# passwords known to be breached (Have I Been Pwned, via privacy-preserving
# k-anonymity — only a 5-char SHA1 prefix ever leaves the server).
class PasswordStrength
  MIN_ZXCVBN_SCORE = 3 # 0..4; 3 = "safely unguessable"

  Result = Struct.new(:code, :message) do
    def ok? = code.nil?
  end
  OK = Result.new(nil, nil).freeze

  def self.check(password)
    if weak?(password)
      return Result.new(:password_weak, "is too weak — use a longer passphrase or less common words")
    end
    if breached?(password)
      return Result.new(:password_breached, "has appeared in a known data breach — choose a different one")
    end
    OK
  end

  def self.weak?(password)
    Zxcvbn.test(password).score < MIN_ZXCVBN_SCORE
  end

  # Best-effort: an HIBP outage (or a network-blocked test env) must never block a
  # legitimate signup, so any error is treated as "not known-breached".
  def self.breached?(password)
    Pwned::Password.new(password).pwned?
  rescue => error
    Rails.logger.warn("[PasswordStrength] HIBP check unavailable, failing open: #{error.class}: #{error.message}")
    false
  end
end
