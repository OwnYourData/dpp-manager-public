# Example answers

A passport form can be filled from a file instead of by hand: on the passport
page, above the form, there is **Load file**. The file is read in
the browser and the form is drawn again from it — nothing is uploaded, and
nothing is saved until you press Save.

That is meant for two situations: showing somebody what the application does
without typing twenty-four fields at them, and the case where the data already
exists in another system and only has to get in here.

## The format

A JSON object. The keys are the attribute names of the SOyA structure behind the
product type — the names in the structure, not the labels on the screen. Values
are plain JSON: strings, numbers, `true`/`false`, and an array where the
structure has a set.

Fields the structure does not know are ignored. Fields the file leaves out stay
empty. Loading a file replaces what is in the form; it does not merge.

The passport's own envelope — the product identifier, the granularity, the
facility — is not part of this. Those are fields of the page around the form and
are typed there.

## What is here

| File | Structure |
|---|---|
| [`led-lamp.json`](led-lamp.json) | `DppLedLamp` — the LED lamp used throughout the documentation |
| [`battery.json`](battery.json) | `DppBattery` — a traction battery, 52 fields and three lists |

The lamp is invented, the shape of the data is not: the attributes follow the
nameplate, technical specification, lifetime, compliance and footprint sections
of an asset administration shell for a real lamp.

The battery is invented as well. Its attributes follow DIN DKE SPEC 99100:2025-02,
Annex A Table A.1, which elaborates Annex XIII of Regulation (EU) 2023/1542 — the
identification, conformity, carbon footprint, due diligence, materials, recycled
content, circularity, end of life and performance sections of it. The decimal
fields deliberately carry real fractional digits: jq has no decimal type, so a
value written as `230.0` comes back as `230`, and a round-trip check would then
fail on a notation rather than on a value.

To write one for a structure of your own, the attribute names are in the
structure's YAML, under `content.bases[].attributes`. Or: fill one passport in
by hand, and take the names from there.
