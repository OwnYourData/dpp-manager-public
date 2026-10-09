# Changelog

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
