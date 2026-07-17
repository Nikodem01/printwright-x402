# The store `rate_limit` macros capture at class-load time. Delegating at call
# time lets tests install a real memory store while the test env's null cache
# keeps limits inert everywhere else in the suite.
class RateLimitStore
  mattr_accessor :backend

  def self.increment(...)
    (backend || Rails.cache).increment(...)
  end
end
