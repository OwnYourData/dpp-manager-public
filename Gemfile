source "https://rubygems.org"

ruby "~> 3.3"

gem "rails", "~> 8.1.3", ">= 8.1.3.1"
gem "propshaft"

# Built from source against libsqlcipher: the whole database file is encrypted,
# and the precompiled platform gem bundles plain SQLite, which cannot open it.
# The build flag lives in .bundle/config; see docs/Decisions.md.
gem "sqlite3", "~> 2.7", force_ruby_platform: true

gem "puma", ">= 6.0"
gem "importmap-rails"
gem "turbo-rails"
gem "stimulus-rails"

# Argon2id, for deriving the database key from the passphrase.
gem "argon2", "~> 2.3"

# did:oyd. The identity DID of the economic operator, and in variant B the
# passport DID, are minted here on this machine — the registrar's REST API would
# carry the private keys over the wire, which is the one thing this application
# exists to avoid. There is no implementation of the method outside this gem.
gem "oydid", "~> 0.9", ">= 0.9.6", require: false

# EdDSA bearer tokens for the DPP Service. jwt ships its algorithms separately;
# without jwt-eddsa the gem does not know EdDSA at all.
# 3.2 carries the fix for CVE-2026-45363, an empty-key HMAC bypass. Reaching it
# needed oydid 0.9.6: until then oydid pinned jwt ~> 3.1.2 and held every
# consumer on the vulnerable release.
gem "jwt", "~> 3.2"
gem "jwt-eddsa", "~> 0.9"


gem "tzinfo-data", platforms: %i[ windows jruby ]
gem "bootsnap", require: false

group :development, :test do
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"
  gem "brakeman", require: false
  # bin/bundler-audit exists in this project and continuous integration runs it,
  # but nothing provided the gem — the binstub failed with a LoadError on every
  # push. It checks the locked gem versions against the advisory database, which
  # for an application whose subject is key material is worth the few seconds.
  gem "bundler-audit", require: false
  gem "rubocop-rails-omakase", require: false
end

group :development do
  gem "web-console"
end
