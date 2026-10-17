import { Controller } from "@hotwired/stimulus"

// The application's own "are you sure?", instead of window.confirm.
//
// window.confirm stops everything: it is a browser dialog, outside the page, so
// a screen reader announces it as something foreign, a test or automation
// cannot reach it, and while it is open nothing on the page runs. Here it is a
// <dialog> in the page: modal, focus moves into it and back, Escape cancels,
// and it reads as part of the application.
//
// Every place that asks keeps saying so the way it always did, with
// data-turbo-confirm. Turbo asks this controller instead of window.confirm. A
// form that Turbo does not handle (data-turbo="false") would otherwise skip the
// question entirely, so those are caught here as well.
export default class extends Controller {
  static targets = ["dialog", "message", "accept", "cancel"]

  connect() {
    if (window.Turbo?.config?.forms) {
      window.Turbo.config.forms.confirm = (message) => this.ask(message)
    }
    this.guard = this.guard.bind(this)
    this.element.addEventListener("submit", this.guard, true)
  }

  disconnect() {
    this.element.removeEventListener("submit", this.guard, true)
  }

  // Forms outside Turbo: hold the submission, ask, and send it again if the
  // answer is yes. The second time through is let pass.
  guard(event) {
    const form = event.target
    if (!(form instanceof HTMLFormElement)) return
    if (form.dataset.turbo !== "false") return

    const submitter = event.submitter
    const message = submitter?.dataset.turboConfirm || form.dataset.turboConfirm
    if (!message) return

    if (form.dataset.confirmed === "yes") {
      delete form.dataset.confirmed
      return
    }

    event.preventDefault()
    event.stopImmediatePropagation()
    this.ask(message).then((yes) => {
      if (!yes) return
      form.dataset.confirmed = "yes"
      form.requestSubmit(submitter || undefined)
    })
  }

  ask(message) {
    const dialog = this.dialogTarget
    this.messageTarget.textContent = message
    this.returnFocus = document.activeElement

    return new Promise((resolve) => {
      const finish = (answer) => {
        this.acceptTarget.removeEventListener("click", accept)
        this.cancelTarget.removeEventListener("click", cancel)
        dialog.removeEventListener("cancel", cancel)
        if (dialog.open) dialog.close()
        this.returnFocus?.focus?.()
        resolve(answer)
      }
      const accept = () => finish(true)
      const cancel = (event) => {
        event?.preventDefault()
        finish(false)
      }

      this.acceptTarget.addEventListener("click", accept)
      this.cancelTarget.addEventListener("click", cancel)
      dialog.addEventListener("cancel", cancel)

      dialog.showModal()
      // Cancel has the focus: Enter on an unread question should not be the
      // one keystroke that does the thing that cannot be undone.
      this.cancelTarget.focus()
    })
  }
}
