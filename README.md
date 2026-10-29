# DPP Manager

> ℹ️ **Public snapshot.** This repository is a snapshot of an internal
> development repository, published without history and refreshed
> periodically. Pull requests here cannot be merged — please open an issue
> instead, or contact [OwnYourData](https://www.ownyourdata.eu).

A graphical application for the economic operator, for creating and managing
digital product passports without a command line. It runs as a container on the
operator's own computer and keeps everything in one encrypted file in a
directory they choose.

It is a pure client. It calls the OwnYourData DPP Service over its HTTP API and
changes nothing about that service.

## What this version does

A passport can be taken all the way through its life: filled in, given an
identifier of its own, handed to the DPP Service, kept at a custodian of the
operator's choosing, corrected, read back by anybody who holds its identifier,
and ended.

- One encrypted file in a mounted directory holds everything: settings, keys,
  product types, passports and the event log.
- A passphrase creates that file on first run and opens it afterwards. There is
  no way in without it. The application locks itself after a period without use.
- The operator's identity is a `did:oyd` minted on this machine. Its two keys
  are shown once and never leave the file. Its document key authenticates the
  operator to the DPP Service and signs what the operator stands behind.
- Product types are SOyA structures. They are fetched once and cached, and from
  then on the form, the validation and the transformation work without a
  network — soya-web-cli runs beside Rails and pulls every structure back out of
  this application.
- The image ships with product types already in it, transformations included
  (`soya/bundled.yml`). A new data file starts with them, so the first passport
  can be filled in without anybody typing a repository address — and without a
  network, because the structures are in the image as well. "Fetch again" still
  asks the repository; the copy in the image is only the fallback.
- The form itself is soya-form, embedded, so a passport looks the way its author
  meant it to. Its answers can also come from a file — a JSON object keyed by
  the structure's attribute names, read in the browser and never uploaded — for
  a demonstration, or for data that already exists in another system.
- Each passport gets its own `did:oyd`, minted here, pointing at where the
  passport will be readable. Its keys stay in the file too.
- Submitting builds the EN 18223:2026 document — the envelope from the settings
  and the identity, the elements from the type's transformation — signs it with
  the operator's identity and sends it as CreateDPP.
- A submitted passport stays editable, and the difference between what is here
  and what the service holds is said out loud. Sending it is an act of its own
  (UpdateDPP, RFC 7396), not a side effect of saving.
- A passport can be kept at a custodian rather than in the service's own
  database. The authority for that is a mandate: one signed sentence naming one
  passport, one collection and one lifetime, signed here with the operator's
  identity, renewable in a click and revocable without asking anybody. Mandates
  running out are shown on the overview before they expire.
- The content of a passport is bound to its identifier. After every submission
  and every correction, the hash the service reports for the bytes the custodian
  delivers is written into the passport's DID document, signed with the
  passport's own document key, which never leaves this computer. The passport
  page shows the attested hash and when it was written, and a handover to
  another custodian keeps it. Anybody can check it with
  `bin/verify_dpp <carrier link>` from the DPP Service, needing nothing from
  either side.
- A passport the DPP Service keeps in its own database carries the signature
  of its economic operator. After every submission, correction and change of
  access policy the application reads the passport as any reader receives it,
  signs it with the operator's identity and hands the signature to the
  service, which delivers it with the passport on request. The passport page
  shows the state the service reports, and says so when the service accepted
  the signature as that of an authorised representative. Passports without a
  signature yet are signed in one go from the list of passports. A passport held by a
  custodian carries no such signature yet, and its page says why.
- Every write names its request: the token signed for it carries the hash of
  the method, the address and the body, so the service keeps it as the
  operator's statement of exactly which change they asked for.
- Not every field of a passport has to be public. On the page *Access
  classes* of a product type each element of its passports is public, for
  readers with a legitimate interest, or for authorities only. The page lists
  the elements the type's transformation produces, with the form fields that
  end up in each, and starts from the classes the SOyA structure suggests in
  an `OverlayClassification` — the bundled lamp and battery carry one. Switched
  on, the classes become the access policy of the type: it is registered with
  the DPP Service under a versioned identifier and named in every passport of
  the type; the service then hands each reader only what its class allows.
  Switched off, passports stay public as a whole.
- On the page *Access rights* the operator grants a reader with a legitimate
  interest — a repair shop, a recycler — access to some or all of their
  passports for at most a year. The right is signed here with the operator's
  identity and registered with the service, which checks it on every read.
  Revoking it ends it at once. Comparing with the service shows rights its
  operator revoked and whom it trusts to vouch for authorities; rights for
  authorities are not the operator's to give.
- Any passport can be read from its identifier alone — the product identifier
  through the service, or the passport's own `did:oyd`, which is resolved and
  then read wherever its document says it lives. No identity and no permission
  are needed for what is public, because that is what a passport is for.
- Ending a passport is two acts in one order: the service stops serving it and
  keeps the final state as history, then the identifier is revoked with the keys
  kept here. After that it resolves nowhere.
- Everything that happens is entered in a hash-chained event log.
- German and English throughout, switchable, English by default. Each page
  explains itself; the explanations can be switched off.

Still to come: roles, so that more than one person can act for one operator.
Moving a passport between two different custodian hosts works and is exercised,
but has not yet been run end to end against two real hosts.

### The two identifiers

They are easy to confuse and nothing works if they are.

The **product identifier** is the string on the data carrier — a GS1 Digital
Link or an identification link under a domain the operator controls. No length
is enforced: the EU registry accepts up to 2000 characters, and how much the
carrier bears is the operator's decision.

Without a custodian the passport stays in the DPP Service's own database, and a
scanned identifier reaches it only on a host the service answers on; the
service names those hosts in its discovery document. A new passport's
identifier therefore starts on the first of them, and the passport page warns
when an identifier is on a host the service does not answer on. A host of the
operator's own works the same way once it points at the service and the service
answers on it.

The **passport identifier** is the `did:oyd` this application mints for the
passport. It carries a `DigitalProductPassport` service entry naming where the
passport can be read, and the DPP Service compares that host with the host it is
being handed to. Both the product identifier and that endpoint are fixed the
moment the DID is minted: changing either means a new identifier and a new
carrier.

## Running it

**[docs/Install.md](docs/Install.md) is the guide** — which container programs
work and what each of them costs, a route that is only clicking and a route that
is one command, where the data ends up, and what to do when something does not
start. It is written for somebody who has never used a container, because that
is who this application is for.

The short version, if you already have Docker:

    docker compose pull && docker compose up -d

with the `docker-compose.yml` from this repository, then open
http://localhost:3000 in a browser. On the first start you choose a passphrase;
from then on that passphrase opens your data.

    docker compose down                        stop it
    docker compose pull && docker compose up -d   fetch a newer version

The image comes from Docker Hub as `oydeu/dpp-manager:latest`, so nothing is
built on the way in. Building it yourself is one command and is what the
development section below assumes:

    docker build -t dpp-manager .

Your data stays in the `data` folder beside the compose file, as a single file,
`dpp.db`. Copying that folder to another computer and starting there with the
same passphrase takes your work with it. On Linux the folder has to belong to
user id 1000, the user inside the container — `sudo chown 1000:1000 data` — and
the application says so if it cannot write there.

### Losing the passphrase

There is no recovery. Not by us, not by anyone. The file is encrypted with a key
derived from the passphrase and from nothing else. Write it down somewhere safe.

## Working on the code

Ruby 3.3 and a SQLCipher 4 library are needed.

**Do not use the distribution package.** Debian ships SQLCipher 3.4, built on
SQLite 3.15 — below what Active Record requires, and a different file format
from SQLCipher 4. Build it, the same version the container uses:

    apt-get install build-essential pkg-config git libssl-dev
    git clone --depth 1 --branch v4.6.1 https://github.com/sqlcipher/sqlcipher.git
    cd sqlcipher
    ./configure --prefix=/usr/local --enable-tempstore=yes --disable-tcl \
      CFLAGS="-DSQLITE_HAS_CODEC -DSQLITE_TEMP_STORE=2 -O2" LDFLAGS="-lcrypto"
    make -j4 && make install && ldconfig

`-DSQLITE_HAS_CODEC` is not optional and its absence is silent: without it the
SQLCipher sources build into plain SQLite, `PRAGMA key` is accepted and ignored,
and the vault is written in the clear. Check with:

    sqlcipher :memory: "PRAGMA cipher_version;"

That has to print a 4.x version, not nothing.

On macOS the objection above does not apply — Homebrew ships SQLCipher 4, so the
library comes from there:

    brew install sqlcipher
    sqlcipher :memory: "PRAGMA cipher_version;"

The formula is keg-only, so the gem has to be told where its pkg-config file is.
That belongs in your shell profile and **not** in `.bundle/config`: that file is
part of the repository and carries only `--with-sqlcipher`, which is true
everywhere. A path out of one computer's Homebrew tree would break the image
build.

    export PKG_CONFIG_PATH="$(brew --prefix sqlcipher)/lib/pkgconfig:$PKG_CONFIG_PATH"

Bundler has to match the lockfile, or every command spends a moment installing
the right version and re-executing itself:

    gem install bundler -v "$(awk '/^BUNDLED WITH$/ { getline; gsub(/[[:space:]]/, ""); print; exit }' Gemfile.lock)"

Then the gem, against that library:

    export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig
    bundle config set build.sqlite3 --with-sqlcipher
    bundle install

That build flag is not optional either. Without it bundler installs the
precompiled `sqlite3` gem, which bundles plain SQLite and cannot open an
encrypted file. The `Gemfile` pins `force_ruby_platform` for the same reason.

`test/lib/library_test.rb` checks all of this and fails loudly if the library
underneath is not SQLCipher 4.

A changed structure goes to the repository with `soya init-push`, which stores
the YAML next to the JSON-LD:

    cat soya/DppLedLamp.yaml | soya init-push

Not `soya init | soya push`: that stores the JSON-LD only, and the form is
built from the YAML. A product type fetched again from a structure without
YAML is refused, and the type keeps the version it had.

Then refresh the copies the image carries:

    bin/rails soya:bundle

It writes the JSON-LD of every bundled structure into `soya/` and stops with a
message when the repository serves no YAML for a structure, or another YAML
than the one beside it.

Run the tests:

    bin/rails test

Run the application against a directory of your choosing:

    DPP_DATA_DIR=/tmp/dpp-daten bin/rails server

### Environment

| Variable | Default | Meaning |
|---|---|---|
| `DPP_DATA_DIR` | `/data` | the mounted directory the vault file lives in |
| `DPP_DATABASE_FILENAME` | `dpp.db` | the name of the vault file |
| `PORT` | `3000` | the port the server listens on |
| `BIND` | `0.0.0.0` | the interface it binds to |
| `SECRET_KEY_BASE` | generated at boot | only affects session cookies, never the vault |

## Where things are

| Path | What |
|---|---|
| `app/lib/vault/` | the encrypted file: key derivation, opening, re-keying, backups |
| `config/initializers/vault_pragmas.rb` | puts `PRAGMA key` in front of every connection |
| `app/models/event.rb` | the hash-chained event log |
| `app/lib/did/` | minting, resolving, revoking `did:oyd`, and the bearer token |
| `app/lib/soya/` | fetching structures, the local repository, soya-web-cli |
| `app/lib/dpp/` | the product identifier and the EN 18223 document |
| `app/lib/dpp_service/` | discovery and the calls to the DPP Service |
| `app/lib/did/delegation.rb` | the custody mandate: what is signed, and how |
| `soya/` | the structures this project publishes and ships: the lamp, its transformation, and the manifest |
| `config/locales/` | every visible string, in both languages |
| `docs/Install.md` | how to install and run it, for somebody who has never used a container |
| `docs/Decisions.md` | why the pieces are shaped the way they are |
| `docs/examples/` | a file of answers a passport form can be filled from, instead of typing |

`docs/Decisions.md` is worth reading before changing anything about the database
layer. Several of the obvious approaches there do not work, and it records which
and why.

## Funding

<!-- funding:begin -->
The DPP Manager is part of [PACE-DPP](https://dpp-austria.at/) – Promoting and Accelerating a Digital Product Passport based Data-Service Ecosystem. This Lighthouse Project has been made possible by financial contributions from the Austrian Federal Ministry of Innovation, Mobility and Infrastructure ([BMIMI](https://www.bmimi.gv.at/en.html), formerly BMK), supported by the Austrian Research Promotion Agency (FFG) under grant number [917177](https://projekte.ffg.at/projekt/5128301), as well as from the German Federal Ministry of Research, Technology and Space (BMFTR, formerly BMWK), supported by the German Research Promotion Agency (DLR-PT).
<!-- funding:end -->

## Licence

Apache License 2.0 — see `LICENSE`. The same licence as the DPP Service and
SOyA, so the three can be read and used together without a second question.
