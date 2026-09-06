import { Controller } from "@hotwired/stimulus"

// The bridge between the form and the page around it.
//
// soya-form runs in a frame and does not submit anything: it announces the
// current answers with postMessage every time they change, and announces its
// own height so the frame can grow instead of scrolling inside itself. This
// controller keeps the latest announcement in a hidden field, which is what the
// surrounding form posts.
//
// Answers are kept as they arrive rather than read out of the frame at submit
// time: reaching into the frame would mean reading its DOM and guessing which
// input is which field, and the message already carries the parsed values.
export default class extends Controller {
  static targets = ["frame", "answers", "state"]
  static values = { emptyLabel: String, filledLabel: String }

  connect() {
    this.onMessage = this.onMessage.bind(this)
    window.addEventListener("message", this.onMessage)

    // The frame announces its height, but only when it initialises and when
    // something is clicked — a form that grows because a list gained a row, or
    // because a validation message appeared, says nothing. The frame is on this
    // origin, so its document can simply be measured, and that covers the rest.
    this.fit = this.fit.bind(this)
    this.lastHeight = 0
    this.timer = setInterval(this.fit, 400)
    this.frameTarget.addEventListener("load", this.fit)
  }

  disconnect() {
    window.removeEventListener("message", this.onMessage)
    this.frameTarget.removeEventListener("load", this.fit)
    clearInterval(this.timer)
  }

  fit() {
    // The body, not documentElement: the root element of a document is never
    // shorter than the viewport it is in, so measuring it means the frame can
    // only ever grow — it would keep whatever height it happened to start with
    // and show a band of empty white under a short form.
    const body = this.frameTarget.contentDocument?.body
    if (!body) return

    const height = body.scrollHeight
    // A shrinking frame that follows every intermediate measurement flickers
    // while the form settles; a threshold keeps it still.
    if (height > 0 && Math.abs(height - this.lastHeight) > 8) {
      this.lastHeight = height
      this.frameTarget.style.height = `${height + 24}px`
    }
  }

  onMessage(event) {
    // Same origin only. The frame is served by this application, so anything
    // arriving from elsewhere is not the form — and the message carries what
    // ends up saved, so this is not a formality.
    if (event.origin !== window.location.origin) return
    if (event.source !== this.frameTarget.contentWindow) return

    const message = event.data || {}

    if (message.type === "data") {
      this.answersTarget.value = JSON.stringify(message.data || {})
      this.showState(message.data)
    }

    if (message.type === "update") this.fit()
  }

  showState(data) {
    if (!this.hasStateTarget) return

    const filled = Object.values(data || {}).filter(
      (value) => value !== null && value !== "" && !(Array.isArray(value) && value.length === 0)
    ).length

    this.stateTarget.textContent =
      filled === 0 ? this.emptyLabelValue : this.filledLabelValue.replace("%{count}", filled)
  }
}
