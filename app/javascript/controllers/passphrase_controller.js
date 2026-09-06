import { Controller } from "@hotwired/stimulus"

// The strength indicator on the create screen.
//
// It rates in the browser and never sends the passphrase anywhere; the same
// estimate exists server-side in Vault::Passphrase, which is the one that
// actually decides. This is feedback while typing, not a gate.
//
// The wording comes out of the DOM, not out of this file, so that the indicator
// speaks whichever language the page is in.
export default class extends Controller {
  static targets = ["input", "meter", "fill", "label"]

  connect() {
    const strings = document.querySelector(".meter-strings")
    this.labels = {
      too_short: strings?.dataset.strengthTooShort ?? "",
      weak: strings?.dataset.strengthWeak ?? "",
      fair: strings?.dataset.strengthFair ?? "",
      strong: strings?.dataset.strengthStrong ?? ""
    }
  }

  assess() {
    const value = this.inputTarget.value
    if (value.length === 0) {
      this.meterTarget.hidden = true
      return
    }
    this.meterTarget.hidden = false

    const level = this.level(value)
    const width = { too_short: 15, weak: 35, fair: 65, strong: 100 }[level]

    this.fillTarget.style.width = `${width}%`
    this.fillTarget.className = `fill ${level}`
    this.labelTarget.textContent = this.labels[level]
  }

  level(value) {
    if (value.length < 12) return "too_short"

    let pool = 0
    if (/[a-z]/.test(value)) pool += 26
    if (/[A-Z]/.test(value)) pool += 26
    if (/[0-9]/.test(value)) pool += 10
    if (/[^a-zA-Z0-9]/.test(value)) pool += 33
    if (pool === 0) pool = 26

    const unique = new Set(value).size / value.length
    const bits = Math.floor(value.length * Math.log2(pool) * unique)

    if (bits < 60) return "weak"
    if (bits < 90) return "fair"
    return "strong"
  }
}
