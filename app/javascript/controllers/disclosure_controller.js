import { Controller } from "@hotwired/stimulus"

// Show/hide for the quoted history under a message.
//
// Deliberately not <details>/<summary>: the trigger needs to sit inline in the
// message's own rhythm with its own label text swapping, and a summary marker
// would be the one rounded, decorated thing on the page.
export default class extends Controller {
  static targets = ["trigger", "panel"]

  toggle() {
    const open = this.panelTarget.hidden

    this.panelTarget.hidden = !open
    this.triggerTarget.textContent = open ? "Hide quoted text" : "Show quoted text"
    this.triggerTarget.setAttribute("aria-expanded", open ? "true" : "false")
  }
}
