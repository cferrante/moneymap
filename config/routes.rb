Rails.application.routes.draw do
  mount RailsIcons::Engine, at: "/rails_icons"
  get "home/index"
  get "dashboard" => "dashboard#show", as: :dashboard
  get "reports" => "reports#show", as: :reports
  resource :session
  resources :passwords, param: :token
  get  "invitations/:token", to: "invitation_acceptances#new", as: :invitation_acceptance
  post "invitations/:token", to: "invitation_acceptances#create"
  resource :settings, only: %i[ edit update ]
  resources :user_sessions, only: %i[ destroy ] do
    collection do
      delete :destroy_all
    end
  end
  resources :accounts, except: :show
  resources :categories, except: :show
  resources :transactions, except: :show
  resources :budgets, except: :show
  resources :transfers, only: %i[ new create edit update destroy ]

  namespace :admin do
    resources :feature_flags, only: %i[ index update ] do
      resources :feature_flag_assignments, only: %i[ create destroy ], as: :assignments
    end
    resources :invitations, only: %i[ index create destroy ]
  end
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  root "home#index"
end
