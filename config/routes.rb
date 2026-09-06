Rails.application.routes.draw do
  root "dashboard#show"

  get    "unlock", to: "unlock#show",    as: :unlock
  post   "unlock", to: "unlock#create"
  delete "unlock", to: "unlock#destroy", as: :lock

  resource :settings, only: %i[show update], controller: "settings"

  get  "vault",                  to: "vault#show",              as: :vault
  post "vault/passphrase",       to: "vault#change_passphrase", as: :vault_passphrase
  post "vault/backup",           to: "vault#backup",            as: :vault_backup

  get  "setup",                to: "setup#show",                as: :setup
  post "setup/service",        to: "setup#configure_service",   as: :setup_service
  post "setup/identity/mint",  to: "setup#mint_identity",       as: :setup_mint_identity
  post "setup/identity/import", to: "setup#import_identity",    as: :setup_import_identity
  post "setup/keys",           to: "setup#secure_keys",         as: :setup_keys
  post "setup/custodian",      to: "setup#configure_custodian", as: :setup_custodian

  get  "identity",             to: "identities#show",           as: :identity
  post "identity/export",      to: "identities#export_keys",    as: :identity_export
  post "identity/check",       to: "identities#check_keys",     as: :identity_check

  # A GET, and not only out of REST piety: reading a passport changes nothing,
  # the answer is worth linking to, and a form that POSTs to a page which
  # renders rather than redirects is a form Turbo refuses to display — the
  # button would do nothing at all in a browser, while every test that speaks
  # plain HTTP would pass.
  get  "lookup",       to: "lookups#show",  as: :lookup
  post "lookup/draft", to: "lookups#draft", as: :lookup_draft

  resources :passports, except: :show do
    member do
      post "mint"
      post "submit"
      post "correct"
      post "retire"
      post "delegation/renew", action: :renew_delegation, as: :renew_delegation
      post "delegation/check", action: :check_delegation, as: :check_delegation
      post "custody/move",     action: :move_custody,     as: :move_custody
      post "custody/finish",   action: :finish_move,      as: :finish_move
      get  "keys",        action: :keys
      post "keys/secure", action: :secure_keys, as: :secure_keys
      post "keys/export", action: :export_keys, as: :export_keys
    end
  end

  resources :product_types, except: :show, path: "product-types" do
    post :refresh, on: :member
    post :install_bundled, on: :collection, path: "install-bundled"
  end

  resources :events, only: :index

  # This application, seen from soya-web-cli: a SOyA repository serving what the
  # vault holds. Loopback only, and it is what makes the form work without a
  # network. The paths are soya-js's, not ours — pull is a plain GET on the
  # name — so the route shape is fixed by the library, not chosen.
  # What the embedded soya-form page fetches while it renders. The paths are
  # fixed in its own source, not chosen here.
  scope "api", module: "soya", as: "form_api" do
    get "runtime-config",   to: "form_api#runtime_config"
    get "repo/query",       to: "form_api#query"
    get "repo/:name/yaml",  to: "form_api#yaml", constraints: { name: %r{[^/]+} }
    get "form/:name",       to: "form_api#form", constraints: { name: %r{[^/]+} }
  end

  scope "soya", module: "soya", as: "soya" do
    get "api/soya/query", to: "repository#query"
    get ":name/yaml",     to: "repository#yaml", constraints: { name: %r{[^/]+} }
    get ":name",          to: "repository#show", constraints: { name: %r{[^/]+} }
  end

  # Liveness only. Deliberately does not touch the database: the application is
  # meant to be up and answering while the vault is still locked, and a health
  # check that connected would make that impossible to observe.
  get "up", to: proc { [ 200, { "content-type" => "application/json" }, [ '{"status":"ok"}' ] ] }
end
