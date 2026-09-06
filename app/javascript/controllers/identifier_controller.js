import { Controller } from "@hotwired/stimulus"

// The product identifier, read back to the operator while they type.
//
// Two things are worth saying at that moment and useless afterwards. The length:
// fifty characters is the entire budget, it is spent on the host and the serial,
// and finding out from a rejected submission that the host is four characters
// too long is finding out too late to do anything cheap about it.
//
// And the granularity. For a GS1 Digital Link the path already says whether this
// is a model, a batch or one item — /21/ means a serial number, so it is an
// item, and no declaration to the contrary will be accepted. So the field is
// filled in from the path rather than offered as a choice the operator can get
// wrong. It stays editable, because an identification link has an opaque path
// and there the declaration is all there is.
//
// The same rules run again in Ruby, and again at the service. This is the layer
// that talks; the ones behind it are the ones that decide.
export default class extends Controller {
  static targets = ["field", "granularity", "count", "derived"]

  static MAX_LENGTH = 50

  connect() {
    this.derive()
  }

  derive() {
    const value = this.fieldTarget.value.trim()

    this.showLength(value)
    this.showGranularity(this.granularityFromPath(value))
  }

  showLength(value) {
    if (!this.hasCountTarget) return

    const over = value.length - this.constructor.MAX_LENGTH
    this.countTarget.textContent = value.length === 0 ? "" : `${value.length}/50`
    this.countTarget.className = over > 0 ? "over" : ""
  }

  showGranularity(derived) {
    if (!this.hasGranularityTarget) return

    if (!derived) {
      if (this.hasDerivedTarget) this.derivedTarget.textContent = ""
      return
    }

    // Only fill an empty field. Overwriting a choice somebody made would be
    // right most of the time and infuriating the once it is not — and the
    // contradiction is caught on saving anyway, with a sentence that explains it.
    if (this.granularityTarget.value === "") this.granularityTarget.value = derived

    if (this.hasDerivedTarget) {
      this.derivedTarget.textContent = this.derivedTarget.dataset.label || ""
    }
  }

  // The path of a GS1 Digital Link: /01/<14 digits> and at most one of each
  // qualifier. Anything else is either an identification link, whose path says
  // nothing, or a mistake — and neither yields a granularity here.
  granularityFromPath(value) {
    let path
    try {
      const url = new URL(value)
      path = url.pathname
    } catch {
      return null
    }

    const segments = path.replace(/\/+$/, "").replace(/^\//, "").split("/")
    if (segments.length < 2 || segments.length % 2 !== 0) return null
    if (segments[0] !== "01" || !/^\d{14}$/.test(segments[1])) return null

    const qualifiers = new Set()
    for (let i = 2; i < segments.length; i += 2) qualifiers.add(segments[i])

    if (qualifiers.has("21")) return "item"
    if (qualifiers.has("10")) return "batch"
    return "model"
  }
}
