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
  static targets = ["frame", "answers", "state", "file", "loadState"]
  static values = {
    emptyLabel: String,
    filledLabel: String,
    loadedLabel: String,
    loadFailedLabel: String
  }

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

  // A file of answers poured into the form.
  //
  // The file is read here and never sent anywhere: it goes into the hidden
  // field and into the frame's address, and the frame renders itself again from
  // it. That is the whole mechanism — no upload, no endpoint, and nothing to
  // clean up on the server if somebody picks the wrong file.
  //
  // Replace, not merge. Merging would leave the operator looking at a form
  // holding two sources at once with no way to tell which value came from
  // where, and "load this file" is a sentence about a whole document.
  load(event) {
    const file = event.target.files && event.target.files[0]
    if (!file) return

    const reader = new FileReader()
    reader.onerror = () => this.failed(event.target)
    reader.onload = () => {
      let data
      try {
        data = JSON.parse(reader.result)
      } catch (error) {
        this.failed(event.target)
        return
      }

      // A JSON document can be an array, a number or null just as well as an
      // object. Only an object is a set of answers.
      if (data === null || typeof data !== "object" || Array.isArray(data)) {
        this.failed(event.target)
        return
      }

      this.apply(data, file.name)
      event.target.value = ""
    }
    reader.readAsText(file)
  }

  apply(data, name) {
    this.answersTarget.value = JSON.stringify(data)

    // Re-rendering by address rather than by postMessage into the frame: the
    // form already knows how to start from answers, because that is how an
    // existing passport is opened. Reusing that path means there is one way in.
    const src = new URL(this.frameTarget.src, window.location.href)
    src.searchParams.set("data", this.answersTarget.value)
    this.frameTarget.src = src.toString()

    this.showState(data)
    this.report(this.loadedLabelValue.replace("%{file}", name))
  }

  failed(input) {
    input.value = ""
    this.report(this.loadFailedLabelValue)
  }

  report(text) {
    if (this.hasLoadStateTarget) this.loadStateTarget.textContent = text
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
