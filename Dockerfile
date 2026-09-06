# Two stages. The build stage carries the compilers, because SQLCipher itself is
# built here, and with it two gems from source: sqlite3 against that library, and
# argon2, which compiles its own libargon2 wrapper. The runtime stage carries
# neither.
#
# jq is in the runtime image although nothing uses it yet: the transformation of
# passport data (milestone 2) runs through it, and rebuilding the image
# definition for that later is churn for no reason.

ARG RUBY_VERSION=3.3.6

# SOyA, pinned to a commit rather than a branch or a published image.
#
# Not the images on Docker Hub, although they exist: oydeu/soya-web-cli:latest
# is a year older than its newest dated tag, and the dated tags are amd64 only —
# the arm64 build lives under a separate tag. Building from source here means
# the operator's machine decides the architecture, and the pin means two people
# building this image a month apart get the same SOyA.
#
# 5f57dc5 is soya-web-cli 0.5.1 over soya-js 0.10.1, and soya-form 0.6.0.
ARG SOYA_REPO_URL=https://github.com/OwnYourData/soya.git
ARG SOYA_REF=5f57dc5231e9af274ddf8f5380b0404e94138328
ARG NODE_VERSION=24-bookworm-slim

# SQLCipher 4.x. Not the distribution package: Debian bookworm ships SQLCipher
# 3.4, which is built on SQLite 3.15 -- below the 3.23 that Active Record
# requires, and a different file format from SQLCipher 4. Pinning the version
# here also means the container and a developer's machine agree about the format
# of the operator's file, which a distribution upgrade could otherwise change
# underneath us.
ARG SQLCIPHER_VERSION=v4.6.1

FROM ruby:$RUBY_VERSION-slim AS build

ARG SQLCIPHER_VERSION

# tcl is needed even though the build passes --disable-tcl: that switch only
# turns off the TCL bindings, while the makefile still runs tclsh to generate
# the amalgamation. Without it the build fails at has_tclsh84, several minutes
# in.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      build-essential pkg-config git ca-certificates tcl \
      libssl-dev libffi-dev libyaml-dev && \
    rm -rf /var/lib/apt/lists/*

# -DSQLITE_HAS_CODEC is not optional and its absence is silent: without it the
# SQLCipher source tree builds into plain SQLite, `PRAGMA key` is accepted and
# ignored, and the vault ends up written in the clear. The application checks for
# the codec on every connection for the same reason.
RUN git clone --depth 1 --branch "$SQLCIPHER_VERSION" https://github.com/sqlcipher/sqlcipher.git /tmp/sqlcipher && \
    cd /tmp/sqlcipher && \
    ./configure --prefix=/usr/local --enable-tempstore=yes --disable-tcl \
      CFLAGS="-DSQLITE_HAS_CODEC -DSQLITE_TEMP_STORE=2 -O2" LDFLAGS="-lcrypto" && \
    make -j"$(nproc)" && make install && \
    ldconfig && \
    /usr/local/bin/sqlcipher :memory: "PRAGMA cipher_version;" | grep -q . && \
    rm -rf /tmp/sqlcipher

WORKDIR /rails

ENV RAILS_ENV=production \
    BUNDLE_DEPLOYMENT=1 \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT=development \
    PKG_CONFIG_PATH=/usr/local/lib/pkgconfig

COPY Gemfile Gemfile.lock ./

# The base image ships whichever bundler was default for its Ruby (2.5.22 for
# 3.3.6), and the lockfile was written by a newer one. Bundler notices, fetches
# the version the lockfile names and re-executes itself. That works, but it
# costs a download on every build and prints a warning that reads like a
# problem — so the version is installed first, and read out of the lockfile
# rather than written down here, because a second place to state it is a second
# place for it to be wrong.
RUN bundler_version="$(awk '/^BUNDLED WITH$/ { getline; gsub(/[[:space:]]/, ""); print; exit }' Gemfile.lock)" && \
    test -n "$bundler_version" || { echo "Gemfile.lock names no bundler version" >&2; exit 1; } && \
    gem install bundler -v "$bundler_version" --no-document && \
    bundle --version

# The flag that makes the whole design work: without it bundler installs the
# precompiled sqlite3 gem, which bundles plain SQLite and cannot open an
# encrypted file. The Gemfile pins force_ruby_platform for the same reason.
RUN bundle config set build.sqlite3 --with-sqlcipher && \
    bundle install && \
    rm -rf ~/.bundle "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git

# Proves the gem really reached the codec, at build time rather than in front of
# the operator.
RUN bundle exec ruby -e 'require "sqlite3"; v = SQLite3::Database.new(":memory:").execute("PRAGMA cipher_version").flatten.first; abort("no SQLCipher codec in the sqlite3 gem") if v.to_s.empty?; puts "sqlite3 gem linked against SQLCipher #{v}"'

COPY . .

# The scripts in bin/ are executable in the image whatever they were on the
# machine the build ran from. A checkout on Windows, an editor that rewrites a
# file, a tool that copies content without the mode — any of them silently drops
# the bit, and the container then dies before the first line of the entrypoint
# with "permission denied" and nothing else. Line endings for the same reason:
# a CRLF makes the shebang name an interpreter that does not exist.
RUN chmod +x bin/* && sed -i 's/\r$//' bin/*

RUN bundle exec bootsnap precompile app/ lib/ && \
    SECRET_KEY_BASE_DUMMY=1 bundle exec rails assets:precompile


FROM node:$NODE_VERSION AS soya

ARG SOYA_REPO_URL
ARG SOYA_REF

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y git ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# The whole repository, because web-cli depends on soya-js as `file:../lib2` —
# it is not published to npm at this version, which is also why the build order
# below is lib2 first and then web-cli against it.
RUN git clone "$SOYA_REPO_URL" /src && cd /src && git checkout --quiet "$SOYA_REF"

# soya-js. Its build output has to stay at /lib2: web-cli's node_modules/soya-js
# is a symlink to that path, and moving it turns every require into a dangling
# link that only fails at the first request.
RUN cd /src/lib2 && npm install --no-audit --no-fund && npm run build && npm prune --omit=dev && \
    cp -a /src/lib2 /lib2

RUN cd /src/web-cli && npm install --no-audit --no-fund && npm run build && npm prune --omit=dev && \
    mkdir -p /soya-web-cli && \
    cp -a /src/web-cli/dist /src/web-cli/node_modules /src/web-cli/package.json /src/web-cli/http-openapi.json /soya-web-cli/

# soya-form, built to static files. It renders and does not compute: the schema
# comes from web-cli, the structure from the application. Serving it from Rails
# rather than from its own little server keeps this to one HTTP surface — and
# same-origin, which is what lets the page listen to its postMessage.
#
# --base is not cosmetic: the SPA is served from /soya-form/ here rather than
# from the root of its own little server, and without it every asset in the
# built index.html points at the root and the page stays blank. Its calls to
# /api/... are absolute in the source and stay at the root, which is where this
# application answers them.
RUN cd /src/form && npm ci --no-audit --no-fund && npx vite build --base=/soya-form/ && \
    mkdir -p /soya-form && cp -a /src/form/build/. /soya-form/


FROM ruby:$RUBY_VERSION-slim

# libsodium is loaded by rbnacl through FFI, and only when a key is first
# generated — not at require time. A runtime image without it therefore starts
# perfectly, serves every page, and fails at the one moment that matters: the
# operator pressing "create an identity". Hence the check further down.
#
# libstdc++6 and libgcc-s1 are for the node binary copied in below, which is not
# a package here and brings no dependencies of its own.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      libssl3 libffi8 libyaml-0-2 libsodium23 libstdc++6 libgcc-s1 jq tzdata curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /rails

ENV RAILS_ENV=production \
    BUNDLE_DEPLOYMENT=1 \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT=development \
    RAILS_LOG_TO_STDOUT=1 \
    DPP_DATA_DIR=/data \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    SOYA_WEB_CLI_URL=http://127.0.0.1:8081 \
    SOYA_FORM_ROOT=/soya-form

COPY --from=build /usr/local/lib/libsqlcipher.so* /usr/local/lib/
RUN ldconfig

COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build /rails /rails

# The same again, because this is a fresh base image with the same old default
# bundler. The gems are already here — what is missing is the bundler the
# lockfile names, and without it every `bundle exec` below, and every one at
# runtime, goes through the switch-and-re-exec dance again.
RUN bundler_version="$(awk '/^BUNDLED WITH$/ { getline; gsub(/[[:space:]]/, ""); print; exit }' Gemfile.lock)" && \
    gem install bundler -v "$bundler_version" --no-document && \
    bundle --version

# The second runtime. Just the interpreter — no npm, no toolchain: nothing in
# this image installs a package, and everything Node needs was built in the
# stage above.
COPY --from=soya /usr/local/bin/node /usr/local/bin/node
COPY --from=soya /lib2 /lib2
COPY --from=soya /soya-web-cli /soya-web-cli
COPY --from=soya /soya-form /soya-form

# Everything the application needs from outside Ruby, checked HERE rather than in
# the build stage — this is the image that ships, and it has its own copy of the
# libraries. Each of these three has already broken once:
#
#   the SQLCipher codec  — without it PRAGMA key is accepted and ignored
#   libsodium via rbnacl — loaded lazily, so its absence surfaces at the first
#                          key generation and nowhere earlier
#   oydid                — parses a non-ASCII table at require time and needs a
#                          UTF-8 locale to load at all
#
# A build that fails here costs a minute. The same failure in front of the
# operator costs their trust in the one screen that cannot be repeated.
RUN bundle exec ruby -e ' \
  require "sqlite3"; \
  v = SQLite3::Database.new(":memory:").execute("PRAGMA cipher_version").flatten.first; \
  abort("no SQLCipher codec: the vault would be written unencrypted") if v.to_s.empty?; \
  require "rbnacl"; RbNaCl::Random.random_bytes(8); \
  require "oydid"; \
  puts "runtime ok: SQLCipher #{v}, libsodium via rbnacl, oydid loaded"'

# The same for the Node half, and for the same reason: soya-web-cli starts
# fine and only fails when something asks it for a form, which is in front of
# the operator. So it is started here, asked, and stopped.
#
# The version endpoint is enough — it exercises the interpreter, the copied
# node_modules and the symlink from web-cli to /lib2, which is the part that
# breaks if the build ever moves soya-js somewhere else.
#
# Two things this check has to get right, because getting either wrong makes it
# fail on a build that would have worked:
#
# From /soya-web-cli, because that is where it has to be started — it locates its
# own package.json with find-root over the working directory, not over the
# script's path.
#
# And on the same ports the entrypoint uses. soya-web-cli defaults to 8080 and
# puts its internal repository proxy on the next one up — so asking 8081 without
# setting PORT reaches the *proxy*, which dutifully forwards the question to
# soya.ownyourdata.eu, where /api/v1/version does not exist. The process is fine;
# the check is asking the wrong door.
#
# `export` and not `PORT=8081 exec …`: assignments in front of a special builtin
# set a shell variable and are not exported, so the program that replaces the
# shell never sees them. It starts perfectly — on the default port.
RUN set -e; \
    test -f /soya-form/index.html || { echo "soya-form was not built: there would be no form to render" >&2; exit 1; }; \
    (cd /soya-web-cli && export PORT=8081 REPO_PROXY_PORT=8082 && exec node dist/index.js) >/tmp/soya.log 2>&1 & \
    soya_pid=$!; \
    ok=""; \
    for i in $(seq 1 30); do \
      if curl -fsS http://127.0.0.1:8081/api/v1/version >/tmp/soya-version.json 2>/dev/null; then ok=yes; break; fi; \
      sleep 1; \
    done; \
    kill "$soya_pid" 2>/dev/null || true; \
    if [ -z "$ok" ]; then echo "soya-web-cli did not answer:" >&2; cat /tmp/soya.log >&2; exit 1; fi; \
    echo "runtime ok: node $(node --version), $(jq -r '.name + " " + .version' /tmp/soya-version.json), soya-js $(jq -r '.soyaJsVersion' /tmp/soya-version.json), soya-form built"; \
    rm -f /tmp/soya.log /tmp/soya-version.json

# Not root. The data directory is a mount from the operator's machine, so its
# ownership comes from there — the entrypoint checks it is writable and says so
# plainly rather than failing halfway through creating a vault.
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    mkdir -p /data log tmp storage && \
    chown -R rails:rails /data /rails
USER 1000:1000

VOLUME /data
EXPOSE 3000

# Answers while the vault is still locked, and touches no database.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s \
  CMD curl -fsS http://127.0.0.1:3000/up || exit 1

ENTRYPOINT ["/rails/bin/docker-entrypoint"]
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
