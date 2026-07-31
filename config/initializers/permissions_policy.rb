# Rails already sets the framing, sniffing and referrer headers, and
# content_security_policy.rb handles script and connect origins. This closes the
# remaining gap: the browser features a marketplace page has no business asking
# for, denied for the page and every frame inside it.
#
# Set as a default header rather than through `config.permissions_policy`. That
# DSL still emits the superseded `Feature-Policy` header, in the old
# `camera 'none'` syntax, which current browsers ignore — so configuring it that
# way would look like protection while doing nothing. The modern header uses
# `camera=()` and is spelled out here verbatim. Verified by reading the response
# headers off a running server, not by trusting the framework default.
#
# Deliberately narrow. Only the hardware and payment capabilities nothing here
# uses are denied; motion sensors, fullscreen and picture-in-picture are left
# alone because the model preview legitimately reaches for them on mobile, and a
# policy that breaks a real feature gets ripped out wholesale rather than fixed.
#
# Note for anyone reading this next to the x402 code: `payment=()` refers to the
# browser Payment Request API, which this app does not use. Buying happens over
# HTTP 402 plus a wallet signature, and is unaffected.
# Assigned on the response class, not on `config.action_dispatch.default_headers`:
# the Action Dispatch railtie copies that config into this attribute before
# `config/initializers/*` runs, so merging into the config here would be
# silently discarded. This is the value actually read when a response is built.
ActionDispatch::Response.default_headers =
  ActionDispatch::Response.default_headers.merge(
    "Permissions-Policy" => "camera=(), microphone=(), geolocation=(), usb=(), " \
      "serial=(), hid=(), midi=(), payment=(), idle-detection=()"
  )
