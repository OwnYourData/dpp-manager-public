# Changelog

## 0.1.14

- **The form says what is wrong in words.** The checks of the passport form
  used to show the messages of the validator underneath, with internal field
  names in them. They are now short sentences in the language of the page:
  required, needed as soon as the field it belongs to is filled in, an address
  that starts with https://, at most so many characters, and the like. A
  message the DPP Manager does not recognise is still shown as it comes.
- The warning about an identifier on a host the DPP Service does not answer on
  no longer says that only pointing that host at the service helps. Whether
  scanning leads to the passport depends on who answers on that host: a host
  of your own that points at the service, or a custodian that passes
  identifiers it does not know on to the service.
- **No product type without its YAML.** The form is built from the YAML of a
  structure. When *Fetch again* gets a structure from the repository without
  it, the DPP Manager takes the YAML it ships with if the structure is the
  same, and otherwise refuses the fetch with a message saying so; the product
  type keeps the version it had.

## 0.1.13

- **A passport without a custodian starts on a host that leads to it.** The
  DPP Service names the hosts on which it answers the identifiers printed on
  products. Without a custodian, the product identifier of a new passport
  starts on the first of them, for the DPP Service of OwnYourData
  `https://id.ownyourdata.eu/01/`, so that scanning the product leads to the
  passport. A host of your own works the same way once it points at the
  service and the service answers on it. The start left as it is is not saved
  as an identifier.
- The passport page warns when the identifier of a passport that stays with
  the DPP Service is on a host the service does not answer on: scanning the
  product does not lead to that passport.
- With a custodian nothing changes.

## 0.1.12

- **The documents of an LED lamp name their file type.** Beside the address of
  the declaration of conformity and of the dismantling instructions, the form
  asks what the address serves — PDF, HTML, plain text, PNG, JPEG or MP4 — and
  requires it as soon as the address is given. The passport carries it as the
  media type EN 18223 asks of a related resource; nothing is guessed from the
  address. An LED lamp type created before this release gets the new fields
  with *Fetch again*, and a passport submitted before keeps its documents
  without a file type until it is corrected.
- What a form makes required once another field is filled in is checked again
  when a passport is saved or submitted, not only while typing.

## 0.1.11

- **Passports are signed by their economic operator.** After every
  submission, correction and change of access policy of a passport the DPP
  Service keeps in its own database, the DPP Manager reads the passport as any
  reader receives it, signs it with the key of your identity and hands the
  signature to the service. The passport page shows the state the service
  reports, says so when the service accepted the signature as that of an
  authorised representative, and names the reason when a signature did not go
  through, with a button to sign again. *Sign all passports that wait for it*
  on the list of passports signs those that carry no signature yet. A passport
  held by a custodian is not signed, and its page says why.
- **Every write names its request.** The token signed for a write carries the
  hash of its method, address and body. The DPP Service keeps it as your
  statement of exactly which change you asked for, and from 1 December 2026
  it accepts no write without it.
- New identities declare their key for signing (`assertionMethod`) as well as
  for authenticating; existing identities stay as they are.
- The event log and the card *Your data file* no longer run over the edge on
  narrow screens.
- References to the integrity standard name EN 18246:2026.

## 0.1.10

- The bar links on the right to the DPP Service your passports are submitted
  to, and the footer leads to the DPP Service with its Knowledge Base, Linter
  and Validator and to the source code, and names the version.
- The key page of a new passport identifier says that its keys stay visible
  until you confirm that they are stored, as the setup does for the keys of
  your identity.
- When the container cannot write to its data folder, its log gives the same
  remedy as the page and the installation guide, Docker Desktop on macOS and
  Windows included.
- Setup names the handover of a passport by the title the passport page gives
  it, *Hand this passport to another custodian*.
- Rails is updated to 8.1.4.

## 0.1.9

- **A custodian without the service's reader is explained.** When the DPP
  Service refuses a passport because the custodian has not entered its reader
  for the collection, the passport page says so in your language, names the
  custodian and the collection, and shows the reader to pass on with a button
  that copies it. A refused handover keeps what was typed into its form.
  - The refusal is recognised by the code the DPP Service gives it,
    `readerNotEntered`, and no longer by its English wording; from a service
    without the code, the wording still counts. Where the refusal does not
    name the reader, the page shows the one the service publishes for that
    custodian.
- **The German pages say *Collection* throughout.** The section on who holds
  a passport called it *Sammlung*; it now says *Collection*, as setup and the
  handover do.
- **Smaller corrections.**
  - Saving the settings records only what changed, and the explanations as on
    or off.
  - The container name in `docker-compose.yml` can be set in `.env`
    (`DPP_MANAGER_CONTAINER`) and stays `dpp-manager` by default, so a second
    DPP Manager can run next to the first.
  - While the data folder cannot be written to, the passphrase cannot be
    entered, and the page and the installation guide also say what to check
    with Docker Desktop on macOS and Windows.
  - On the passport form, *Your identity* is said of the economic operator only,
    not of the passport identifier below it.
  - After submission, an empty *Placed on the market on* names the day of
    submission the period started on, and claims no period where the product
    type sets none.
  - The keys of your identity are shown until you confirm that they are stored,
    as the setup now says, and not afterwards, also when that step is opened
    again.

## 0.1.8

- **The automatic lock no longer throws work away.** When the data file locks
  itself while a form is open, what is sent next is not carried out — and now
  the application says so: on the unlock screen, and again after unlocking,
  which leads back to the page the form was on. The browser puts back what was
  typed, except passphrases, keys and files. The event log records the lock
  together with the action that was not carried out.
  - The data file also closed itself after five minutes without use,
    whatever the setting said, without a log entry or a message. It now stays
    open for exactly the time set under *Settings*.
- **A data folder the container cannot write to is explained.** Instead of an
  error page, the unlock screen says which folder or file cannot be written and
  by which user id, and nothing is written. The container also refuses to start
  when an existing data file belongs to another user. The installation guide
  says how to fix the ownership on Linux.
- **Confirmations are part of the page.** "Are you sure?" is a dialog in the
  application instead of the browser's own box: usable with the keyboard and a
  screen reader, Escape cancels, and the focus starts on *Cancel*. Handing a
  passport to another custodian asks for confirmation now as well.
- **Times say which zone they are in.** Every time is shown in UTC and labelled
  so, the same time base as the event log, the DPP Service and the custodian.
- **Texts say what actually happens.**
  - Creating a passport identifier: the product identifier and the passport
    identifier are fixed; where it points can be changed later by handing the
    passport to another custodian, and both identifiers stay the same.
  - The keys of a passport are shown until you confirm that they are stored,
    and the link to them says so.
  - Setup: step 1 is the first of four; the named custodian holds passports and
    does not run this application.
  - Submitting: the passport identifier has to point at the host where the
    passport will be read — the custodian's when one holds it.

## 0.1.7

- **The passphrase no longer reaches the log.** Up to 0.1.6, creating the data
  file, opening it and changing its passphrase wrote the passphrase in plain
  text into the container's log, where `docker logs` shows it. The passphrase
  fields are now filtered, and so are the keys and the prepared revocation of
  an identity or a passport. Statements that carry the key of the data file
  bypass the SQL log, and when one of them fails, the error no longer quotes
  it.
  - After the update, create the container anew; the old log goes with the
    old container:
    `docker compose pull && docker compose up -d --force-recreate`.
    Started with `docker run` instead: remove the container with
    `docker rm -f` and run it again with the new image.
  - If you have passed a log of this container on to anyone, change the
    passphrase (*Data file* → *Change the passphrase*).
- **The footer names the funding.** Below the line about the application, in
  smaller type, the footer says that the DPP Manager is part of PACE-DPP and
  how it is funded. The README carries the same notice under *Funding*.
- **The installation starts with `docker compose pull`,** in the README and in
  the installation guide, so a computer that still holds an older image starts
  the current one.
- **The image says what it is.** `docker image inspect` shows the version and
  the commit it was built from, as `org.opencontainers.image.version` and
  `org.opencontainers.image.revision`.

## 0.1.6

- **Not every field of a passport has to be public.** A product type now has a
  page *Access classes*: every element its passports carry, with the form
  fields that end up there, is public, for readers with a legitimate interest,
  or for authorities only. Which field lands at which element is worked out by
  running the type's transformation. The classes start from what the SOyA
  structure suggests in an `OverlayClassification`; the bundled lamp and battery
  carry one. Switched on, the classes are registered with the DPP Service as
  the type's access policy, under a versioned identifier, and named in every
  passport of the type when it is created or corrected (`X-DPP-Access-Policy`).
  The passport page shows how well the policy fits the passport and moves a
  passport that is already at the service to a newer version. Switched off,
  nothing changes.
- **Readers with a legitimate interest can be let in.** A new page *Access
  rights* grants a reader, known by its DID, access to some or all of the
  operator's passports for at most a year. The right is signed with the
  operator's identity and registered with the DPP Service, which checks it on
  every read; it is kept here only when the service takes it. Revoking ends it
  at once. *Compare with the service* takes over rights the operator of the
  service revoked and shows whom the service trusts to vouch for authorities.
  Rights for authorities are not offered.
- **The data file gains the tables for both.** It is brought up to date the
  next time it is opened; take a backup copy first.

## 0.1.5

- **Passports are read in the full representation.** A DPP service answers in
  the compressed representation of EN 18223:2026 5.2 unless the request asks
  for the full one (EN 18222:2026 8.1). Creating, correcting, moving and
  reading a passport now ask for `representation=full`, so the lookup keeps
  showing the element tree and the copy kept after a submission stays
  complete. A custodian that knows no such flag ignores it.

## 0.1.4

- **DPP services are reached over HTTP/2.** EN 18216:2026 clause 4 makes
  HTTP/2 the minimum version for DPP data exchange, and DPP services may refuse
  older ones. Every call to a DPP service and to a custodian now negotiates
  HTTP/2; a server that offers nothing but HTTP/1.1 is still answered. SOyA
  repositories are not DPP data exchange and are reached as before.
- **A passport knows how long it has to stay available.** It takes the day
  the product was placed on the market. At submission the availability period
  is worked out from that day (or from the submission, without it) and the
  years the product type prescribes, sent to the service as
  `X-DPP-Retain-Until`, and shown on the passport. Ending a passport before
  that day is refused. The passport also keeps a snapshot of what it was issued
  under: the product type's configuration with its version, and which copy of
  the structure and transformation it was built from.
- **A product type says what the law says about it.** Beside its SOyA
  structure a product type now carries the legal configuration of its product
  group (ESPR Art. 9): the legal act and the period it is in force, the day from
  which a passport is required, the granularity, the permitted data carriers,
  where the carrier goes and how it looks, and how many years a passport stays
  available. All of it is optional. Every change counts up a configuration
  version, shown in the list. A new passport starts with the prescribed
  granularity, and one that differs is flagged before it is submitted — it can
  still be sent on purpose.
- **A handover keeps the payload attestation.** Moving a passport to another
  custodian used to rebuild its DID document from scratch and drop the
  `payloadHash` it carried, so the passport read as unattested afterwards. The
  document is now read and only the endpoint changes.
- **A passport that does not meet its structure is not submitted by accident.**
  Submitting and sending a correction now check the answers against the product
  type first. What is wrong is named, and a second, deliberate click sends it
  anyway — recorded in the log as such, because the structure itself can be
  wrong and the operator has to be able to say so.
- **No length limit on identifiers.** The product identifier and the custodian
  address are no longer length-checked. The form still shows how long the
  identifier is, because what goes on a data carrier is the operator's call.
- **What is wrong with a passport reads as a sentence.** An empty mandatory
  field says "is required" instead of "Less than 1 values", and a field whose
  structure words its own message in several languages shows that message, in
  the language of the interface, instead of the name of an internal node. The
  summary above a shortened list counts all points, not the lines shown.
- **Granularity follows the identifier as it is typed.** A GS1 Digital Link
  passes through `/01/<GTIN>` before its qualifier arrives, and the field used to
  stop at "model" there. It now follows the path to "batch" or "item" for as
  long as the value is the one the form filled in; a choice the operator made
  is never overwritten.

## 0.1.3

- **The footer names OwnYourData.eu and links to it.** Quietly, in the colour of
  the sentence around it and underlined only under the cursor, and in a new tab:
  an application holding an open vault should not navigate away from itself
  because somebody read the footer.

## 0.1.2

- **The content of a passport is bound to its identifier.** After every
  submission and every correction, the application takes the hash the service
  reports for the bytes the custodian delivers and writes it into the passport's
  DID document, signed with that passport's document key — the key that never
  leaves this computer. A new **Content binding** section on the passport page
  shows the attested hash and when it was written. It happens by itself; the
  button beside it is the way back when the registry could not be reached, so a
  passport never sits silently unattested.
  This is variant B of the procedure: the service can compute the commitment but
  cannot sign it, and it does not need to, because the party that owns the
  identifier is the one running this application. Anybody can check the result
  with `bin/verify_dpp <carrier link>` from the DPP Service, needing nothing
  from either side.
- **A second product type ships with the image: a traction battery.** Its
  attributes follow DIN DKE SPEC 99100:2025-02, Annex A Table A.1, which
  elaborates Annex XIII of Regulation (EU) 2023/1542 — 52 attributes in ten
  sections, from identification and carbon footprint through materials, recycled
  content and circularity to performance, plus critical raw materials, hazardous
  substances and documents as lists. A fresh vault now offers both the LED lamp
  and the battery without a repository address being typed.
- **An example for it** in `docs/examples/battery.json`, complete, so a demo
  opens a filled passport through **Load file**. The test that guards these
  files now covers every bundled type rather than the lamp alone.
- **Ruby 3.3.8** in development and in the image.

## 0.1.1

- **A passport form can be filled from a file.** Above the form there is now
  **Load file**: a JSON object whose keys are the attribute names of the
  structure. The file is read in the browser and the form is drawn again from
  it — nothing is uploaded, nothing is saved until Save is pressed, and loading
  replaces what is in the form rather than merging into it. Meant for showing
  the application without typing two dozen fields at an audience, and for data
  that already exists somewhere else.
- **An example of such a file** ships with the project, in `docs/examples/`,
  complete for the LED lamp the documentation uses. A test checks it against the
  structure, so it cannot drift out of date unnoticed.

## 0.1.0

The first published version. A digital product passport can be taken through its
whole life on the operator's own computer, without a command line.

- **One encrypted file.** Settings, keys, product types, passports and the event
  log live in a single SQLCipher file in a directory the operator mounts. A
  passphrase creates it and opens it; there is no recovery and no second copy.
- **An identity of the operator's own.** A `did:oyd` minted on this machine. Its
  keys are shown once and never leave the file. Everything sent to the service
  is signed with it — there is no account and no password anywhere.
- **Product types from SOyA**, fetched once and then working without a network.
  The image ships with types and transformations already in it, so the first
  passport can be filled in offline.
- **Forms drawn by soya-form**, so a passport looks the way the author of its
  structure meant it to.
- **An identifier per passport**, minted here, naming where the passport will be
  readable. Both that address and the product identifier are fixed at minting.
- **Submission** builds the EN 18223:2026 document from the structure's own
  transformation and sends it as CreateDPP.
- **Correction** as an act of its own, with the difference from what the service
  holds shown before it is sent.
- **Custody at a data intermediary.** The passport lives at a custodian rather
  than in the service's database, and the authority for that is a mandate: one
  signed sentence about one passport, ninety days, revocable at the custodian
  without asking the service. Mandates running out are shown before they expire.
- **Reading any passport** from its identifier alone, with no identity and no
  permission — through the service by product identifier, or by resolving the
  passport's own DID and reading it wherever that document says it lives.
- **Ending a passport**: withdrawn from the service, which keeps the final state
  as history, then the identifier revoked with the keys held here.
- **A hash-chained event log** of everything that happened.
- **German and English**, switchable, English by default, with an explanation on
  every page that can be switched off.

Known limits in this version: the content is signed in transport but carries no
signature of its own, there is one operator per installation rather than roles,
and moving a passport between two different custodian hosts has been exercised
but not yet run against two real ones.
