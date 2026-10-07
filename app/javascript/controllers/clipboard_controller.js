import { Controller } from "@hotwired/stimulus"

// Copies the source target's text — the settings page's freshly issued MCP
// token and the command that uses it. Both are shown exactly once, so a
// one-click copy matters more here than anywhere else.
//
// The Clipboard API needs a secure context (https, or localhost). Where it is
// missing or refused, the text is selected instead, so ⌘C still works.
export default class extends Controller {
  static targets = ["source", "label"]

  async copy() {
    try {
      await navigator.clipboard.writeText(this.sourceTarget.textContent.trim())
      this.confirm()
    } catch {
      window.getSelection().selectAllChildren(this.sourceTarget)
    }
  }

  confirm() {
    this.labelTarget.textContent = "Copied"
    clearTimeout(this.timer)
    this.timer = setTimeout(() => (this.labelTarget.textContent = "Copy"), 1500)
  }

  disconnect() {
    clearTimeout(this.timer)
  }
}
