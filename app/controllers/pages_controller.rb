# Static site-legal pages. Templates, honestly labeled — reviewed text
# replaces them before any mainnet launch.
class PagesController < ApplicationController
  allow_unauthenticated_access

  def terms; end
  def privacy; end
  def takedown; end
  def badge; end
  def about; end
  def pricing; end

  def agent_sellers
    @sellers = [
      {
        name: "Printwright", service: "Machine-paid 3D print licenses",
        endpoint: "/api/v1/models/{id}/download", href: docs_path,
        network: "Hedera testnet", asset: "HBAR or testnet USDC", price: "per model offer",
        verification: "Full sandbox conformance + real testnet settlement evidence"
      },
      {
        name: "Current Weather", service: "Current and historical weather by coordinate",
        endpoint: "https://x402.shizu.me/weather?lat=52.52&lon=13.40",
        href: "https://x402.shizu.me/weather?lat=52.52&lon=13.40",
        network: "Base mainnet", asset: "USDC", price: "$0.003/request",
        verification: "x402 v2 challenge header observed; indexed by CDP Bazaar"
      },
      {
        name: "Weather Forecast & Air Quality", service: "Forecast and AQI by coordinate",
        endpoint: "https://api.kadec0.xyz/v1/weather?lat=52.52&lng=13.41",
        href: "https://api.kadec0.xyz/v1/weather?lat=52.52&lng=13.41",
        network: "Base mainnet", asset: "USDC", price: "$0.005/request",
        verification: "x402 v2 challenge header observed; indexed by CDP Bazaar"
      }
    ]
  end

  def open_books
    @snapshot = OpenBooks::Snapshot.call
  end

  # Endpoint reference is rendered from the spec at request time, not
  # hand-duplicated, so the page and public/openapi.json can't drift apart.
  def docs
    @openapi = JSON.parse(Rails.root.join("public/openapi.json").read)
  end
end
