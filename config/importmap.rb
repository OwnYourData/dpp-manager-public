# Pin npm packages by running ./bin/importmap
#
# Everything here is served from the gems, not from a CDN and not from a
# node_modules directory: the application has to work on a machine with no
# network at all, and there is no build step in this milestone.
pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"
