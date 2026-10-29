namespace :soya do
  desc "Refresh the bundled JSON-LD copies in soya/ from the repository and check that it serves their YAML"
  task bundle: :environment do
    problems = Soya::Bundled.refresh!
    abort problems.join("\n") if problems.any?

    puts "Run the tests: they compare the bundled transformation with the YAML beside it."
  end
end
