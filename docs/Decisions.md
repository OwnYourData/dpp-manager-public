# Decisions

The choices in here are the ones a later reader will question. Each one records
what was decided, why, and what it costs.

## The SQLCipher library

### Built from source, pinned, not taken from the distribution

Debian bookworm — the base of the `ruby:3.3-slim` image — ships SQLCipher 3.4,
which is built on SQLite 3.15.2. Two things are wrong with that at once: it is
below the SQLite 3.23 that Active Record requires, so the application refuses to
start against it; and SQLCipher 3 and 4 write **different file formats**, so a
vault created under one does not open under the other.

That second point is why this is not a version bump but a pin. The format of the
operator's file must not depend on which distribution the base image happens to
be built on this year. `SQLCIPHER_VERSION` in the Dockerfile is the one place
that decides it.

### -DSQLITE_HAS_CODEC, and why it is checked three times

Without that define the SQLCipher source tree builds into **plain SQLite**. The
library works, the gem links against it, `PRAGMA key` is accepted — and silently
ignored. The vault is then written in the clear and nothing in the system
notices. It is the worst failure mode in this application: everything appears to
function and the one property that matters is gone.

So it is asserted three times, each at a point where it can still be caught:

| Where | What it catches |
|---|---|
| Dockerfile, after `make install` | a build that produced a library without the codec |
| Dockerfile, after `bundle install` | a gem that linked against the wrong library |
| `VaultPragmas#configure_connection`, every connection | a machine whose library was swapped underneath |

`test/lib/library_test.rb` asserts the same three facts for a development
machine, including that the major version is 4 and not 3.

### Also not the distribution's runtime package

`libsqlcipher0` on Debian and `libsqlcipher1` on Ubuntu are not the same
software with different names; they are different major versions. An earlier
version of this Dockerfile tried one and fell back to the other, which looked
tolerant and was in fact a coin flip over the file format. The built library is
copied out of the build stage instead.

## The database file

### Everything in one file, encrypted as a whole

The economic operator has to be able to take their work to another computer by
copying it. That rules out a companion file for keys or key-derivation
parameters, and it rules out a directory.

Encrypted as a whole rather than field by field, because the passport list has
to stay sortable, filterable and searchable in SQL. Per-column encryption would
move that work into Ruby and lose it at the first thousand rows.

### The salt is the first sixteen bytes of the file

SQLCipher writes a random 16-byte salt into the first sixteen bytes and leaves
them unencrypted, because it needs them itself before any key exists. Those same
sixteen bytes are the Argon2id salt. One file, no companion, nothing derived
from a constant.

On creation the application generates the salt and hands SQLCipher the 48-byte
key form — 32 key bytes followed by 16 salt bytes — so that SQLCipher stores
that salt. On opening the sixteen bytes are read back, the key is derived, and
the same form is passed again.

**What was tried first and abandoned.** `PRAGMA cipher_plaintext_header_size`
looked like a way to reserve space in the file for a header of our own. It is
not: the bytes it leaves in the clear are the real SQLite header, which SQLite
itself uses, and setting it *removes* the salt from the file rather than making
room beside it — which is why it obliges the caller to supply `cipher_salt` on
every open. The pragma solves a different problem (letting tools recognise the
file as SQLite) and would have cost a companion file for the salt.

### Argon2id, not SQLCipher's PBKDF2

The passphrase is the only secret in the system and it is chosen by a person.
Memory-hardness is what makes guessing expensive on hardware the attacker owns.
The derived 32 bytes are passed as a *raw* key, which bypasses SQLCipher's own
PBKDF2 entirely rather than stacking two derivations.

Parameters: t=3, 64 MiB, p=4 — about half a second on an office machine.

**Where the parameters live: nowhere in the file.** There is no room beside the
salt and no honest place to put them. Instead every profile the application has
ever shipped stays listed in `Vault::Kdf::PROFILES`, and opening tries them
newest first. A file written by an older version keeps opening, and
`Vault::Session.profile` reports which profile answered, so a re-key can be
offered. The cost is one extra Argon2 run per obsolete profile on the way to a
correct passphrase — today there is one profile, so none.

### journal_mode = DELETE, not WAL

WAL means a `-wal` and a `-shm` file beside the database, and the requirement is
one file the user can copy. A single local writer gains nothing from WAL.

Precisely: with DELETE there is never a `-wal` or a `-shm`. A `-journal` exists
only while a write is in flight, and after a crash mid-write it stays behind
*deliberately* — it is the rollback journal, and the next open consumes it.
Deleting it by hand would corrupt the database. `journal_mode = OFF` would
remove even that, at the price of crash safety on the user's only copy, which is
not a trade worth making.

### Changing the passphrase re-writes the file, it does not re-key in place

`PRAGMA rekey` rewrites every page of the existing file. An interruption
half-way leaves the user's only copy partly encrypted under each key, with no
way back. Instead: `ATTACH` a fresh file under the new key, `sqlcipher_export`
into it, `fsync`, and move it over the original. The old file stays intact and
readable until the new one is complete on disk.

The current passphrase is verified before anything is created, so a typo costs
nothing.

### Backups use VACUUM INTO

Copying the file with the filesystem while the application runs can capture a
write in flight. `VACUUM INTO` produces a consistent copy. The copy carries the
same key and salt, so it opens with the same passphrase — which is what makes it
useful as a backup rather than as an export.

## Rails

### The application boots with no database connection

The vault is encrypted with a key derived from a passphrase nobody has entered
when the process starts. So Rails comes up connected to nothing, serves the
unlock page, and `Vault::Store` calls `establish_connection` afterwards.

This is what makes two requirements properties of the architecture rather than
promises: the application starts with no network, and there is no way around the
passphrase.

Four Rails conveniences would connect on their own and are therefore off:

| What | Where |
|---|---|
| `ActiveRecord::Migration::CheckPending` middleware | `config.active_record.migration_error = false` |
| `maintain_test_schema!` in `rails/test_help` | `config.active_record.maintain_test_schema = false` |
| transactional tests (open a transaction in `before_setup`) | `self.use_transactional_tests = false` |
| the fixture loader (reaches for a pool in `before_setup`) | `setup_fixtures` overridden to nothing |

There are no fixtures and there cannot be: the schema only exists inside a vault
that a passphrase has opened. Every test creates and discards a real vault, which
also means the creation path is exercised on every run.

`config/database.yml` points at paths under `tmp/` and is never used by the
running application. Rails wants the file to exist; that is all it is for.

### PRAGMA key goes in front of everything, by prepending configure_connection

`PRAGMA key` has to be the first statement on a new connection: SQLCipher
decides then whether the file is readable, and Rails' own pragmas
(`journal_mode`, `foreign_keys`, `synchronous`) are ordinary statements that
would fail first otherwise. Prepending `configure_connection` and running before
`super` is the one point in the adapter's life cycle where that ordering is
guaranteed.

There is no maintained SQLCipher adapter for Active Record.
`config/initializers/vault_pragmas.rb` is the whole of what one would do.

### A wrong key surfaces later than you would expect

SQLite defers touching the file until it is asked something, so a wrong key does
not fail at connect time. It fails at the first statement that reads a page —
and that turns out to be one of the adapter's own pragmas, before any probe of
ours runs. Both the connect and the probe therefore sit inside the same rescue in
`Vault::Store.open!`.

### Locking removes the connection rather than clearing it

`clear_all_connections!` leaves the pool in place with the configuration on it,
so the next stray query quietly opens a fresh connection — and the adapter would
then ask for a key that is gone. `remove_connection` means a query after locking
fails as what it is, "no connection", instead of surfacing as a key error from
deep inside the adapter.

### The session secret is generated at boot and not kept

The only thing the session holds is "this browser has an open vault". A restart
closes the vault, because the key lives in process memory and nowhere else, so a
session that outlived the process would point at nothing. A fresh secret at boot
invalidates exactly the cookies that have already become meaningless, and saves
the operator from managing a secret file beside their data file.

`SECRET_KEY_BASE` is still honoured for anyone who wants otherwise. It has no
bearing on the encryption of the vault.

### Plain HTTP

This listens on the loopback interface of the operator's own machine. A
self-signed certificate there buys nothing and costs every user a browser
warning. The calls the application makes outward — to the DPP Service and the
custodian — are HTTPS.

## The event log

### Hash-chained

Each row carries the digest of the row before it. A row removed or rewritten
afterwards breaks the chain, and `Event.verify_chain` says where. One SHA-256 per
event, which is nothing, and it makes the log a record rather than a list.

It is not tamper-proof: whoever can rewrite the database can recompute the whole
chain. It is tamper-evident against edits that do not — which is the realistic
case.

The digest covers the timestamp at microsecond precision, because a coarser
rendering would not survive the round trip through the database.

### Failed unlock attempts are entered afterwards

The log lives inside the vault, so a failed attempt cannot be written when it
happens — there is nothing open to write to. The process counts them and the
count is entered on the first unlock that succeeds. A run of failures that never
succeeded therefore leaves no trace, and no design that keeps the log inside the
vault can change that. Moving the log outside the vault would fix it and break
the one-file requirement, which is the more important of the two.

### Kinds are a closed list

They end up in the log view and in both translation files. An open list would let
a typo create a silent second category.

## Bilingualism

Both locale files are compared key for key by a test, and empty values fail it.
Without that the second language falls quietly behind the first and nobody
notices until a user switches. No visible string lives in code or in a template.

The help texts are translations, not code, for the same reason.

## The identity (milestone 1)

### Minting happens here, which is why this is Ruby

The registrar has a REST API that mints a `did:oyd` in one call. It also returns
`documentKey` and `revocationKey` **over the wire**. Those two are the whole
substance of "the identity belongs to the operator", so they must not travel.
That leaves minting locally, and the only implementation of the method is the
`oydid` gem — which is what decided the language of this application.

### Everything from outside Ruby is verified in the image that ships

Three things the application needs are not Ruby code, and each has broken once:
the SQLCipher codec, libsodium behind rbnacl, and oydid's ability to load at all.
They are checked in the **runtime** stage of the Dockerfile, not the build stage
— the runtime image has its own copy of the libraries, and that is the one that
reaches the operator.

libsodium is the reason this matters. rbnacl loads it over FFI at the moment a
key is first generated, not at require time, so an image without it starts
cleanly, serves every page, and fails on "create an identity" — the one screen
that cannot be repeated, because the keys shown there exist nowhere else. A
build that fails costs a minute; that failure costs trust.

`test/lib/library_test.rb` asserts the same three facts for a development
machine. The libsodium check was verified by removing the library and watching
the test fail, then putting it back — a check nobody has seen fail is not a
check.

### LANG has to be set, or the gem cannot even be loaded

`oydid` pulls in `multicodecs`, which parses a non-ASCII CSV table at load time.
With no locale — the normal state of a container — Ruby's default external
encoding is US-ASCII and the require fails several frames deep inside a CSV
parser, with a message that says nothing about locales. The Dockerfile sets
`LANG`, and `config/application.rb` sets the encodings itself rather than
trusting the environment to be right.

### The document key is slot 0, and it is unwrapped from the end

A DID's `key` field is positional: slot 0 signs, slot 1 revokes. Taking `.first`
of a split is right today and wrong the moment a third slot exists, so both
places index explicitly.

The private key decodes to 35 bytes — two varint bytes of multicodec, one length
byte, then the 32-byte seed. The documented way to unwrap it is
`unpack("SCa*")`, which assumes exactly that prefix length; this takes the last
32 bytes instead. Same answer for a well-formed key, and it cannot hand back a
silently shifted 29-byte string, which would produce signatures that verify
nowhere with nothing pointing at the cause.

### The identity DID carries no service entry

A passport DID points at where the passport is served. An actor DID names an
actor and has nothing to point at, so the document is empty apart from its keys.

### The DID goes into a token without its location suffix

For the default repository oydid appends `@https://oydid.ownyourdata.eu` to the
identifier. The DPP Service normalises its own identifiers but resolves a token's
`iss` exactly as written, so the suffix is stripped before the DID is ever
stored — not at the point of use, where one code path would eventually forget.

### The key screen cannot be passed by walking away

Minted keys exist in the vault and in the registrar's answer, which is gone. The
wizard therefore refuses to advance until the operator ticks a box saying they
have them elsewhere, and the step is derived from `keys_secured_at` rather than
from a session — so closing the browser, locking, or restarting all land back on
the same screen. Writing the key file returns to that screen too: being dropped
onto another page would take the keys off the display before they were confirmed.

### Checking the keys is offered as its own action

Sign a token, resolve the DID, verify the signature against the published key.
It exercises the whole chain the service will walk — key material, encoding,
resolution — writes nothing anywhere, and needs the service not to be reachable
at all. It is the one honest answer to "do my keys still work".

### No length is checked on identifiers or addresses

The product identifier is what the data carrier bears. The EU registry accepts
up to 2000 characters for it, and how much a carrier bears is the operator's
decision; the form shows the length while typing, so the decision is made
knowingly. The custodian address goes into each passport DID's `serviceEndpoint`
and never onto a carrier, so it is not length-checked either. The DPP Service
applies the same rule.

### Setup state is derived, never stored in a session

Which step the wizard is on is computed from what is actually configured. An
interrupted setup resumes exactly where it stopped, and asking for a step further
ahead than the state allows falls back rather than rendering a screen whose
prerequisites are missing.

## Appearance

The palette is taken from the OwnYourData logo itself rather than approximated:
`#446DA7` and `#ED9839` are the two halves of the flame, `#1A1919` is the OYD
wordmark, `#85949E` is the "OwnYourData" line. `app/assets/images/oyd-logo.svg`
and `oyd-mark.svg` are cut from the original vector artwork, not redrawn.

**The orange means one thing: this cannot be undone.** The passphrase warning
today, an expiring mandate later. It is deliberately absent everywhere else —
a colour that appears on every second panel stops carrying a message. The blue
is the ordinary accent: links, the primary button, the help panels.

Locking is not the main action on any page and must not look like one, so the
bar's button keeps an outline rather than the filled style. And the bar wraps:
German labels are noticeably longer than English ones ("Ereignisprotokoll"
against "Event log"), so the navigation has to flow onto a second row instead of
assuming it fits.

## Testing

Minitest rather than RSpec, unlike `dpp-service`. One reason: `bin/rails test`
is always present and needs no gem-path dance, which is one less thing to get
wrong on someone else's machine. This is a reversible choice; nothing in the
codebase depends on it.

## SOyA runs here, and the application is its repository

soya-web-cli is soya-js behind an HTTP interface. Putting it in the image means
a second runtime, which is usually the wrong trade; here it is the right one,
because the alternative is deriving forms from the same overlays in Ruby and
getting subtly different ones from every other SOyA tool.

What makes it work offline is one environment variable. soya-web-cli reaches its
repository through a proxy of its own on the loopback address, and that proxy
forwards to whatever `REPO_BASE_URL` names. Pointing it back at this application
means every structure it resolves comes out of the encrypted file. The form, the
acquire and the SHACL validation then run with the network off.

That claim was checked rather than assumed: soya-web-cli's log names exactly one
request, `GETting /<name>` against 127.0.0.1, for the whole cycle.

Three things had to be true first, and each one was silent when it was not.

**The JSON-LD context is not a URL on the document.** It is an `@import` inside
the context object, and soya-js loads it with its own HTTP client — past the
configured repository, straight to ns.ownyourdata.eu. A structure stored for
offline use still drags that behind it. The import resolves it once, while the
network is there anyway, and merges it in.

**A form overlay is only used when the tag is passed.** Asking for a form in a
language returns the *generated* form even when the author wrote one for exactly
that language. No error, no warning. The answer does carry an `options` list, so
the tag can be found and asked for again — but only automatically when there is
one, because two forms for a language is a decision and not a default.

**A form overlay is passed through unchanged.** The annotation's labels are not
merged into it; a control without a `label` shows the attribute name in title
case, in every language. The generated form does read the annotation, which is
what makes the difference easy to miss.

## An HTTP body has no encoding until you give it one

Net::HTTP hands back every body tagged ASCII-8BIT whatever the response said.
That is invisible until the first non-ASCII byte — one German label in a
structure's YAML — and then it surfaces as Encoding::UndefinedConversionError
while saving or rendering, naming a byte rather than a file. Bodies are decoded
at the edge now, with the charset from the header and UTF-8 assumed.

## soya-web-cli has to be started from its own directory

It locates its package.json and its OpenAPI file with find-root over
`path.resolve()` — the *working directory*, not the directory the script lives
in. Started from anywhere else it dies on the first line with "package.json not
found in path", a message that names neither soya-web-cli nor the working
directory and leads nowhere. The published image never hits this because its
WORKDIR happens to be the right one; an entrypoint that starts it with an
absolute path from somewhere else does.

Both places that launch it now `cd` first, and the check in the image is one of
them — which is how this was found, in a build rather than in front of the
operator.

The same check then failed twice more, and both were worth keeping. It defaults
to port 8080 and puts its internal repository proxy on the next one up, so
asking 8081 without setting PORT reaches the *proxy* — which forwards the
question to the configured repository on the internet, where /api/v1/version
does not exist. And `PORT=8081 exec node …` does not set it at all: an
assignment in front of a special builtin sets a shell variable without
exporting it, so the program that replaces the shell never sees it and starts
on the default port, looking perfectly healthy in the log.

## The image does not inherit the host's file modes

bin/docker-entrypoint lost its execute bit on the way to the build machine — a
tool copied the content and not the mode — and the container then died before
the first line of the script with "permission denied" and nothing else. Nothing
in that message points at a file mode.

The build now sets the bit itself, and strips CRLF while it is there, because
the same class of accident produces a shebang naming an interpreter that does
not exist. An image that depends on how a file happened to arrive is an image
that builds on one machine and not on another.

## The identity DID says what it authenticates with

oydid's `authentication: true` writes `authentication: ["#key-doc"]` into the
document, and that section sits inside the hashed payload — so it changes the
identifier and the log hash. It is not a rendering option, and it cannot be
added afterwards: a DID minted without it can only gain it through an update,
which mints a new identifier.

The operator's DID authenticates the operator to the DPP Service, so it should
assert the key it authenticates with. Nothing here depends on it — this
application reads the public key out of the DID's `key` field, slot 0, past
`authentication` entirely, and that field is byte-identical with and without
the flag. What it buys is a document a conformant verifier can use, which is
the difference between an identifier that works with our service and one that
works with anybody's.

The same key also signs the passports the DPP Service keeps, as their economic
operator. A new identity therefore says that too: `assertionMethod:
["#key-doc"]` goes into the content it is minted with. The section is part of
the hashed payload like `authentication`, so an identity minted before keeps
the document it has; changing it would mean a new identifier. Nothing checks
for the section today, neither the service nor dpplint, and an existing
identity signs as before.

The trap it comes with is recorded in the code and repeated here because it is
silent: the option has to be passed again on every update. oydid rebuilds the
document from the content each time, and leaving it out drops the section with
no error and no warning.


## Every write names its request

The DPP Service keeps the token of every write as the operator's statement of
what they asked for, and for that the token carries `rqh`, a hash over the
method, the request-target and the body bytes. Only the client knows those
three once the request is built — the body is serialised there, the query
added there — so the controllers no longer mint the token. They hand the client
a `Did::Token::Bearer`, which says who signs and for which service, and the
client asks it for a token once method, target and body are final, right
before the request goes out. A token minted any earlier would be for a request
that is not the one sent.

A plain string is still taken as a token, unchanged. The tests use that, and so
could a caller that has a token from elsewhere; the service then decides
whether a token without `rqh` is still accepted.

## The economic operator signs what the service delivers

After every write to a passport the DPP Service keeps in its own database —
submission, correction, a new access policy — the application signs it as its
economic operator. What is signed is read from the service, not built here:
the passport as a reader without access rights receives it, in the full
representation. The service compares the signature with exactly that, and
only the service knows how it delivers the passport after the write it has just
made, its own attributes included. The bytes that arrive are signed as they
are, without parsing and serialising them again.

Between the read and the hand-in another write can come in, and the service
then refuses with a sentence that says the passport is no longer the one
delivered. The application reads and signs again, three times at most, and
reports the refusal after that.

Signing is best effort, as attesting the payload is: the write is done when the
service accepted it, and a signature that cannot be handed in must not turn it
into a failure. The passport page shows the state the service reports
(`X-DPP-Signature-State`), the reason a signature did not go through, and a
button to sign again; the list of passports offers to sign every passport that
waits, which covers passports that were never signed.

The service accepts a signature by an identity that is not the passport's
`economicOperatorId`, as that of an authorised representative, and says so in
a warning. The page shows that warning, because a verifier reports such a
signature as not issued by the economic operator.

A passport held by a custodian is not signed: the custodian serves it, and the
service takes no signature for it until the custodian can keep and deliver
one. Its page says so rather than offering a button that cannot work. A
service that reports no signature state at all knows no signature of the
economic operator, and is not asked for one.

## Who may read what

### The class lives on the product type; the structure only suggests it

Whether a field is public, for readers with a legitimate interest or for
authorities is the economic operator's decision, so it is kept per product type
in the data file and changed on the page *Access classes*. A SOyA structure may
carry an `OverlayClassification` with classes of the vocabulary
`https://w3id.org/soya/dpp-access/v1`; those are only the starting point. They
are written as full IRIs, because a classification overlay can hold other kinds
of classes as well ("pii"), and a bare `public` would be ambiguous among them.
Classes of other vocabularies are ignored. A field the overlay does not name is
public; an element no field can be traced to starts as authorities only.

### Which field ends up where is asked of the transformation

The access policy speaks about element paths (`ProductIdentification/SerialNumber`),
the operator about form fields (`serialNumber`). The only place that knows how
one becomes the other is the type's transformation. A table of our own would be
a second opinion about it, so the transformation is run once over marker
answers — every field filled with a value that names it — and the markers are
looked for in the element tree that comes back. Booleans cannot carry a marker
and get a run each. An element whose identifier is itself an answer counts for
the collection around it, and the items of a list count for the path they
share, so that a third item at the service is covered as well. The result is
kept until the structure or the transformation is fetched again.

### A policy version never changes, and a policy is never taken off

The service keeps a registered policy as it is, so a changed set of classes is
a new version under a new identifier, `<operator DID>/access-policies/<structure>/<n>`.
It is registered again before every write that names it, which costs one
request and catches a service that was reset in the meantime; a conflict moves
to the next version. The policy has no default: what no rule reaches is for
authorities. Once a passport is classified by it, the policy of the type cannot
be switched off, because the service has no way of taking it off the passport;
making everything public again is a new version.

### Only a legitimate interest is granted here

An access right for authorities rests on issuers the DPP Service trusts, and an
operator cannot make anybody an authority. The page grants the class
legitimate interest only, for passports the operator holds at that service, for
at most a year, and shows whom the service trusts for authorities.

### A right is revoked, never deleted

Revoking ends a right at the service with effect from now. The entry stays
here, with when and by whom, because what was readable under it has to remain
traceable to it. The signed right is kept as well, so it can be registered
again with a service that lost it.

### Comparing with the service happens when asked for

The service can end a right on its own: its operator revokes on order. What is
here can therefore differ from what counts. Opening the page asks nobody
anything; *Compare with the service* fetches the rights and the list of
authority issuers and says what changed. A right the service does not know any
more is marked rather than removed.

### Local tests use a service DID of their own

A right names the DPP Service it is for, by the service's DID. A test service
started on a laptop with the DID of the production service would accept rights
that also count in production. Local runs therefore mint a DID for the test
service and revoke it afterwards, together with the test identities and test
passports.

## The lock interrupts, it does not discard

The data file closes itself after a while unattended. Whatever is sent after
that moment is not carried out — not partly, not at all — because every check
runs before any action does. What was lost before was everything around that:
the person landed on the unlock screen without being told, and after unlocking
on the overview, with the form they had filled in gone.

Now the request that found the file closed is remembered by where it came from:
which page, and whether it was an action. The lock is logged with that action
named as not carried out, the unlock screen says so, and unlocking leads back
to the page with a message.

The values of the form are deliberately not remembered by the server. A locked
file is supposed to mean that nothing readable is left in the application, and a
copy of a passport's content in the session cookie or in memory would undo that.
They stay where they were typed: the browser tab keeps a copy of the last form
it sent and pours it back into the same form after unlocking. Passwords, files
and every field whose name says it holds a key or a token are never kept, so
those are typed in again.

There was a second way the file closed, and it was not ours. Active Record's
connection pool disconnects connections that sat unused for five minutes, and
the vault's one connection is the vault: it closed after five minutes whatever
the setting said, with no log entry and no message. The pool's idle timeout is
off; the setting decides.

## Times are shown in UTC, and say so

Every time on screen carries its zone, and the zone is UTC. The event log, the
DPP Service, the custodian's trail and every mandate's expiry count in UTC, so a
time copied from this screen into a support request or compared with a log
means the same thing everywhere. The container does not know where its user
sits, and a page that silently converts would show a different number than the
log next to it. Local time in the browser would be friendlier to read and is a
possible addition, but not in place of the zone being named.

## "Are you sure?" is part of the page

Confirmations used to be `window.confirm`: outside the page, announced by a
screen reader as something foreign, unreachable for a test or automation, and
blocking everything while open. They are a `<dialog>` in the page now — modal,
Escape cancels, the focus starts on *Cancel* so that Enter on an unread
question does not do the thing that cannot be undone. Every place keeps asking
the way it did, with `data-turbo-confirm`; forms outside Turbo, which used to
skip the question entirely, are asked as well.

## The product identifier starts where the service answers

A passport without a custodian stays in the DPP Service's own database.
Someone who scans the product reaches it only if its identifier is on a host
the service answers on, and the service names those hosts in its discovery
document (`carrierHosts`). The form therefore starts an empty identifier on the
first of them, as the beginning of a GS1 Digital Link. The start left as it is
is not saved, so a draft is never refused for an identifier nobody typed. The
passport page warns when the identifier of such a passport is on another host:
a warning rather than a refusal, because the operator's own host may still be
pointed at the service.

The list is fetched when the service is set up and when a passport is started,
at most every ten minutes, and kept in the settings. Every other page uses it
as it was last fetched and does not go to the network; a service that cannot
be asked leaves it as it was. With a custodian none of this applies, because
the custodian answers for its passports itself.

## Two repositories, and why the public one has no history

The work happens in a private repository. The public one, `dpp-manager-public`,
receives the current state as a single commit whenever somebody asks for it — by
hand, from the Actions tab, with the word `publish` typed into a field. Nothing
is published because a branch moved.

The reason is not embarrassment about the history. It is that this application
holds key material, and a repository history is the one place from which a
mistake cannot be taken back: a passphrase, a revocation key or an operator's
data file committed once and removed in the next commit is still there, still
fetchable, forever. Publishing a flat snapshot means the only thing that can
ever be exposed is what is in the tree at that moment — which is a thing a
script can check, and does.

Two lists govern what goes: `.publish-exclude` names what is left behind, and
the workflow refuses to push if any of it is still in the tree afterwards. A
second pass looks for the shapes secrets actually have — a private key block, an
oydid secret key, a signed token, credentials in the form Doorkeeper issues them,
a long passphrase next to the word that names it. Both are deliberately
suspicious: a false alarm costs a glance, and a revocation key that got out is
gone.

The single sentence that is true only of the public repository — that it is a
snapshot, and that pull requests there cannot be merged — is inserted into the
README on the way out rather than kept as a second copy of the file. Two
versions of the same README drift, and the README is the file that changes most.

The same arrangement runs for the DPP Service, and deliberately so: one habit for
both, so neither becomes the exception nobody remembers the rules for.
