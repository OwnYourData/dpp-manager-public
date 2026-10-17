import { Controller } from "@hotwired/stimulus"

// What was typed into a form survives the lock that interrupted it.
//
// When the vault locks itself while a form is open, the next submission does
// not reach the action: the server sends it to the unlock screen instead, and
// after unlocking back to the page the form was on. The values themselves are
// kept here, in this browser tab, and nowhere else — not in the session cookie
// and not on the server, where a locked vault is supposed to mean that nothing
// readable is left lying around.
//
// So every submission puts a copy of its fields into sessionStorage. The next
// page either is the one the server names as interrupted (restoreValue), and
// the copy is poured back into the matching form, or it is any other page, and
// the copy is dropped: the submission arrived, and there is nothing to restore.
//
// Never kept: password fields, files, the CSRF token, and every field whose
// name says it holds a secret — the same words the server filters out of its
// log. A key that went missing has to be typed in again; that is the price,
// and it is the right way round.
const STORE = "dpp-manager.resume"
const SECRET = /passw|passphrase|secret|token|_key|key$|revocation|crypt|salt|certificate|mnemonic|seed|delegation|mandate|grant/i
const SKIPPED_TYPES = ["password", "file", "submit", "button", "reset", "image"]
const SKIPPED_NAMES = ["authenticity_token", "_method"]

export default class extends Controller {
  static values = { restore: String }

  connect() {
    this.remember = this.remember.bind(this)
    this.element.addEventListener("submit", this.remember)

    if (this.restoreValue) {
      this.restore(this.restoreValue)
    } else {
      this.forget()
    }
  }

  disconnect() {
    this.element.removeEventListener("submit", this.remember)
  }

  remember(event) {
    const form = event.target
    if (!(form instanceof HTMLFormElement)) return
    if ((form.getAttribute("method") || "get").toLowerCase() === "get") return
    if (form.dataset.resume === "off") return

    const action = this.pathOf(form)
    const index = this.formsFor(action).indexOf(form)
    const fields = []

    for (const element of form.elements) {
      if (!this.keepable(element)) continue
      if ((element.type === "checkbox" || element.type === "radio") && !element.checked) continue
      fields.push([element.name, element.value])
    }

    this.write({ action, index, fields })
  }

  restore(action) {
    const saved = this.read()
    this.forget()
    if (!saved || saved.action !== action) return

    const form = this.formsFor(action)[saved.index] || this.formsFor(action)[0]
    if (!form) return

    const values = new Map()
    for (const [name, value] of saved.fields) {
      if (!values.has(name)) values.set(name, [])
      values.get(name).push(value)
    }

    for (const element of form.elements) {
      if (!this.keepable(element)) continue
      const given = values.get(element.name)

      if (element.type === "checkbox" || element.type === "radio") {
        element.checked = !!given && given.includes(element.value)
      } else if (given && given.length > 0) {
        element.value = given.shift()
      }
    }

    form.dispatchEvent(new CustomEvent("resume:restored", { bubbles: true }))
  }

  keepable(element) {
    if (!element.name || element.disabled) return false
    if (SKIPPED_TYPES.includes(element.type)) return false
    if (SKIPPED_NAMES.includes(element.name)) return false
    if (element.dataset.resume === "off") return false
    return !SECRET.test(element.name)
  }

  formsFor(action) {
    return Array.from(document.forms).filter((form) => this.pathOf(form) === action)
  }

  pathOf(form) {
    return new URL(form.action, window.location.href).pathname
  }

  read() {
    try {
      return JSON.parse(window.sessionStorage.getItem(STORE) || "null")
    } catch (error) {
      return null
    }
  }

  write(value) {
    try {
      window.sessionStorage.setItem(STORE, JSON.stringify(value))
    } catch (error) {
      // A full or disabled storage costs the convenience, nothing else.
    }
  }

  forget() {
    try {
      window.sessionStorage.removeItem(STORE)
    } catch (error) {
      // As above.
    }
  }
}
