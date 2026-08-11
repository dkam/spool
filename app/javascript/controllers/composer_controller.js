import { Controller } from "@hotwired/stimulus"

// The reply box.
//
// Reply and note are one form with a hidden direction field rather than two
// forms, so changing your mind about the audience doesn't cost you the draft.
// Everything here is presentation of that one bit of state.
export default class extends Controller {
  static targets = [
    "form", "direction", "body", "templates", "templatesToggle",
    "modeLabel", "modeToggle", "recipient", "submitLabel"
  ]

  toggleMode() {
    const note = this.directionTarget.value === "outbound"
    this.directionTarget.value = note ? "note" : "outbound"

    this.modeLabelTarget.textContent = note ? "Internal note on" : "Reply to"
    this.modeToggleTarget.textContent = note ? "Reply instead" : "Internal note instead"
    this.submitLabelTarget.textContent = note ? "Save note" : "Send reply"
    this.bodyTarget.placeholder = note
      ? "Write a note for the team…"
      : "Write a reply…"

    // The recipient line is the strongest signal of who will see this, so it
    // has to stop naming the customer the moment the note mode is on —
    // an agent must never be able to glance at a note and think it was sent.
    this.recipientTarget.hidden = note
  }

  toggleTemplates() {
    const open = this.templatesTarget.hidden

    this.templatesTarget.hidden = !open
    this.templatesToggleTarget.textContent = open ? "Hide templates" : "Templates"
    this.templatesToggleTarget.setAttribute("aria-expanded", open ? "true" : "false")
  }

  // Templates are a starting point, never a send. Insert at the cursor when the
  // agent has already written something, so picking one mid-draft doesn't
  // destroy what they typed.
  useTemplate(event) {
    const text = event.params.body || ""
    const field = this.bodyTarget

    if (field.value.trim() === "") {
      field.value = text
    } else {
      const at = field.selectionStart ?? field.value.length
      field.value = field.value.slice(0, at) + text + field.value.slice(at)
    }

    this.toggleTemplates()
    field.focus()
    field.setSelectionRange(field.value.length, field.value.length)
  }
}
