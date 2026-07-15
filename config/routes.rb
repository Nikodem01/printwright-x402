Rails.application.routes.draw do
  resource :session
  resources :passwords, param: :token

  namespace :api do
    namespace :v1 do
      resources :models, only: %i[index show]
      get "models/:model_id/download", to: "downloads#show", as: :model_download
      get "files/:token", to: "files#show", as: :file
      get "certificates/:cert_id", to: "certificates#show", as: :certificate
    end
  end
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  root "storefront#index"
  get "models/:slug", to: "storefront#show", as: :model_page
  get "verify/:cert_id", to: "verify#show", as: :verify
end
