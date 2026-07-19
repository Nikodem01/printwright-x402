Rails.application.routes.draw do
  resource :session
  resources :passwords, param: :token, only: %i[new create edit update]
  resources :designers, only: %i[new create show] do
    member { get :verified_profile }
  end

  namespace :designer do
    resources :models, except: %i[destroy show] do
      member { post :publish }
      resources :versions, only: :create, controller: :model_versions
    end
    resources :imports, only: %i[index new create destroy] do
      collection { post :preview }
    end
    resource :identity, only: %i[show create], controller: :identity do
      post :verify
    end
    resource :takedown_packet, only: %i[new create]
    resources :sales, only: :index
    resources :webhook_endpoints, only: %i[index new create destroy]
  end

  namespace :admin do
    root "dashboard#index"
    resources :purchases, only: [] do
      member do
        post :reconcile
        post :refund
      end
      collection { post :reap }
    end
    resources :licenses, only: [] do
      member { post :retry_certificate }
    end
    resources :designers, only: [] do
      member do
        post :toggle_verification
        post :verify_payout
      end
    end
    resource :payout, only: [] do
      post :preview
      post :run
    end
  end

  namespace :api do
    namespace :v1 do
      resources :models, only: %i[index show]
      resources :batches, only: :create
      get "models/:model_id/download", to: "downloads#show", as: :model_download
      get "files/:token", to: "files#show", as: :file
      get "certificates/:cert_id", to: "certificates#show", as: :certificate
      get "licenses/:id/can", to: "licenses#can", as: :license_permission
      post "licenses/:cert_id/print_reports", to: "print_reports#create", as: :license_print_reports
      get "licenses/:cert_id/latest-version", to: "model_versions#show", as: :license_latest_version
      get "licenses/:cert_id/latest-version/file", to: "model_versions#file", as: :license_latest_version_file
      get "stats", to: "stats#show", as: :stats
      get "sandbox/topics/:topic_id/messages/:sequence_number", to: "sandbox#message",
          as: :sandbox_message
      get "sandbox/files/:cert_id", to: "sandbox#file", as: :sandbox_file
      get "sandbox/transactions/:transaction_id", to: "sandbox#transaction",
          as: :sandbox_transaction
    end
  end
  # System tests stub the demo-wallet daemon with an in-app signer endpoint
  # (same-origin keeps the CSP connect-src untouched). Never mounted outside test.
  # The controller lives outside autoload paths, so it is required here — the
  # constant must resolve for any test-env process, not just the checkout suite.
  if Rails.env.test?
    require Rails.root.join("test/system/support/test_wallet_controller").to_s
    post "__test_wallet__/sign", to: "test_wallet#sign"
  end

  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  get "manifest" => "rails/pwa#manifest", as: :pwa_manifest, defaults: { format: :json }
  get ".well-known/x402-catalog.json", to: "discovery#catalog", as: :x402_catalog,
      defaults: { format: :json }
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  root "storefront#index"
  get "categories/:category", to: "storefront#index", as: :category
  get "collections/:collection", to: "storefront#index", as: :collection
  get "models/:slug", to: "storefront#show", as: :model_page
  get "verify/:cert_id", to: "verify#show", as: :verify
  get "verify/:cert_id/badge", to: "verify#badge", as: :verify_badge, defaults: { format: :svg }
  get "verify/:cert_id/share-card", to: "verify#share_card", as: :verify_share_card,
      defaults: { format: :svg }
  get "verify/:cert_id/certificate", to: "verify#certificate", as: :verify_certificate
  get "receipts/:cert_id", to: "receipts#show", as: :purchase_receipt
  get "receipts/:cert_id/download", to: "receipts#download", as: :purchase_receipt_download
  post "receipts/:cert_id/library", to: "library_memberships#create", as: :receipt_library_membership
  get "library", to: "license_library#show", as: :license_library
  get "library/sign-in", to: "license_library#new", as: :new_license_library
  post "library/sign-in", to: "license_library#create"
  get "library/access", to: "license_library#access", as: :access_license_library
  delete "library", to: "license_library#destroy"
  get "badge", to: "pages#badge", as: :badge_docs
  get "license/:version/:kind", to: "licenses#show", as: :license_document,
      constraints: { version: /v\d+/, kind: /[a-z_]+/ }
  get "terms", to: "pages#terms", as: :terms
  get "privacy", to: "pages#privacy", as: :privacy
  get "takedown", to: "pages#takedown", as: :takedown
  get "docs", to: "pages#docs", as: :docs
  get "about", to: "pages#about", as: :about
  get "pricing", to: "pages#pricing", as: :pricing
  get "open-books", to: "pages#open_books", as: :open_books
  get "agent-sellers", to: "pages#agent_sellers", as: :agent_sellers
  get "chaos-log", to: "pages#chaos_log", as: :chaos_log
  get "chat", to: "chat#show", as: :chat
  post "chat", to: "chat#create"
  post "chat/approve", to: "chat#approve", as: :approve_chat_purchase
end
