import { Controller } from "@hotwired/stimulus"

// Autosaving customer notes.
//
// The design has a status line and no submit button, which is a promise that
// typing is enough. This keeps it: debounce while typing, save on blur, and
// save on the way out of the page so a note is never lost to a navigation.
export default class extends Controller {
  static targets = ["field", "status"]
  static values = { url: String, delay: { type: Number, default: 800 } }

  connect() {
    this.saved = this.fieldTarget.value
    this.flush = this.flush.bind(this)

    // pagehide rather than beforeunload: it fires on mobile tab discard too,
    // and doesn't risk a confirmation dialog.
    this.fieldTarget.addEventListener("blur", this.flush)
    window.addEventListener("pagehide", this.flush)
  }

  disconnect() {
    clearTimeout(this.timer)
    this.fieldTarget.removeEventListener("blur", this.flush)
    window.removeEventListener("pagehide", this.flush)
  }

  schedule() {
    clearTimeout(this.timer)
    this.statusTarget.textContent = ""
    this.timer = setTimeout(() => this.save(), this.delayValue)
  }

  flush() {
    clearTimeout(this.timer)
    this.save()
  }

  async save() {
    const notes = this.fieldTarget.value
    if (notes === this.saved) return

    this.statusTarget.textContent = "Saving…"

    try {
      const response = await fetch(this.urlValue, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content
        },
        body: JSON.stringify({ customer: { notes } })
      })

      if (!response.ok) throw new Error(response.statusText)

      this.saved = notes
      this.statusTarget.textContent = "Saved"
    } catch (e) {
      // Say so rather than showing a false "Saved" — the whole point of the
      // status line is that the agent can trust it.
      this.statusTarget.textContent = "Not saved — check your connection"
    }
  }
}
