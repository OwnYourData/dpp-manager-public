# Changelog

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
