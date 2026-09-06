namespace :soya do
  desc "Refresh the bundled JSON-LD copies in soya/ from the repository"
  task bundle: :environment do
    Soya::Bundled.manifest.each do |entry|
      repo = entry["repo"].to_s

      [ entry["structure"], entry["transformation"], entry["reverse_transformation"] ].compact.each do |name|
        structure = Soya::Repository.fetch(repo, name)
        path = Soya::Bundled.dir.join("#{name}.jsonld")
        path.write("#{JSON.pretty_generate(JSON.parse(structure.jsonld))}\n")

        puts "#{name}: #{path.size} bytes from #{repo}"
      rescue Soya::Error => e
        abort "#{name}: #{e.message}"
      end
    end

    puts "Run the tests: they compare the bundled transformation with the YAML beside it."
  end
end
