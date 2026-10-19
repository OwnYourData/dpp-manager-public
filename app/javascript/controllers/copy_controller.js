import { Controller } from "@hotwired/stimulus"

// Copy a value the operator has to pass on to somebody else, such as the
// reader DID a custodian has to enter, which would otherwise have to be
// selected by hand, character for character.
//
// Without a clipboard to write to (a page not served as a secure context, a
// permission refused) the value is selected instead, so the usual keyboard
// shortcut still copies it.
export default class extends Controller {
  static targets = ["source", "button"]

  async copy() {
    const text = this.sourceTarget.textContent.trim()
    try {
      await navigator.clipboard.writeText(text)
      this.confirm()
    } catch (error) {
      this.select()
    }
  }

  select() {
    const range = document.createRange()
    range.selectNodeContents(this.sourceTarget)
    const selection = window.getSelection()
    selection.removeAllRanges()
    selection.addRange(range)
  }

  confirm() {
    const button = this.buttonTarget
    const label = button.textContent
    button.textContent = button.dataset.copiedLabel || label
    window.setTimeout(() => { button.textContent = label }, 2000)
  }
}
