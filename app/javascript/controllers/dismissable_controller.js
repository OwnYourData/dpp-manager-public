import { Controller } from "@hotwired/stimulus"

// Close a box for now.
//
// Deliberately nothing is remembered. "Close" means this box, on this page, at
// this moment — the operator wants the space back, not a preference. What they
// meant if they want it gone for good is the setting, which is named in the
// same line and which this must not quietly become: a box that stays shut
// without anybody having said so is a setting nobody can find again.
export default class extends Controller {
  dismiss() {
    this.element.remove()
  }
}
