# frozen_string_literal: true

namespace :funding do
  desc "Write the funding notice from config/funding.yml into the README"
  task write: :environment do
    FundingNotice.write!
    puts "written: README.md"
  end
end
