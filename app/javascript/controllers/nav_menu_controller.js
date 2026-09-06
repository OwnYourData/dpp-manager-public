import { Controller } from "@hotwired/stimulus"

// The groups in the bar.
//
// The menu itself is <details>/<summary>, not something built here: it opens and
// closes on its own, it is reachable by keyboard without an ARIA pattern being
// written by hand, and it still works if this file never loads. What <details>
// does not do is behave like a menu once it is open — a click elsewhere leaves
// it hanging, Escape does nothing, and two can be open at once. That is all
// this adds, and it is why the markup is not a pile of divs.
export default class extends Controller {
  static targets = ["menu"]

  connect() {
    // Bound copies, because removeEventListener needs the same function object
    // and `this.closeIfOutside.bind(this)` returns a new one every time it is
    // called — the classic way to leave a listener behind on every Turbo visit.
    this.closeIfOutside = this.closeIfOutside.bind(this)
    this.closeOnEscape = this.closeOnEscape.bind(this)

    document.addEventListener("click", this.closeIfOutside)
    document.addEventListener("keydown", this.closeOnEscape)
  }

  disconnect() {
    document.removeEventListener("click", this.closeIfOutside)
    document.removeEventListener("keydown", this.closeOnEscape)
  }

  // One at a time. `toggle` does not bubble, so the action sits on each
  // <details> rather than on the nav.
  opened(event) {
    if (!event.target.open) return

    this.menuTargets.forEach((menu) => {
      if (menu !== event.target) menu.open = false
    })
  }

  closeIfOutside(event) {
    if (this.element.contains(event.target)) return

    this.closeAll()
  }

  closeOnEscape(event) {
    if (event.key !== "Escape") return

    this.closeAll()
  }

  closeAll() {
    this.menuTargets.forEach((menu) => { menu.open = false })
  }
}
