Rails.application.routes.draw do
  # --- Authentication (owned by OidcAuthController; see docs/auth.md) --------
  # Backchannel logout is a server-to-server POST from the IdP, so it sits
  # outside the browser-facing routes and skips CSRF by virtue of being a
  # signed JWT rather than a form.
  post "/oidc/logout", to: "oidc_auth#backchannel_logout"

  get "/login", to: "oidc_auth#login", as: :login
  get "/login/start", to: "oidc_auth#start_oidc"
  get "/auth/callback", to: "oidc_auth#callback"
  delete "/logout", to: "oidc_auth#logout", as: :logout
  # --- End authentication ---------------------------------------------------

  # Liveness probe for the load balancer: 200 if the app boots without raising.
  get "up" => "rails/health#show", :as => :rails_health_check

  # --- Application routes ---------------------------------------------------
  # UI routes live below. See docs/architecture.md for the four screens and
  # docs/ui.md for how the design maps onto them.

  root "tickets#index"

  resources :tickets, only: %i[index show update] do
    resources :messages, only: %i[create], shallow: true
  end

  # Notes are the only editable field on the customer screen, and they save from
  # a debounced textarea rather than a submit button — hence update with no edit.
  resources :customers, only: %i[show update]

  # Attachment bytes live in the primary SQLite file, not Active Storage, so
  # there is no blob URL to link to — every download is this action. Keyed on
  # the join row because the filename belongs to the join, not the blob.
  get "attachments/:id", to: "attachments#show", as: :attachment
end
