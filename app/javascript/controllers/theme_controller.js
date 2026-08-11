import { Controller } from "@hotwired/stimulus"

// Light/dark switching.
//
// The theme is a client-side preference the server never sees, so the two
// buttons can't be rendered active by Rails — they mark themselves on connect.
//
// The attribute itself is set before first paint by an inline script in the
// layout head; this controller only handles changing it afterwards. Turbo
// replaces <body> and leaves <html> alone, so the choice survives navigation
// without being reapplied.
export default class extends Controller {
  static targets = ["option"]

  static storageKey = "spool:theme"

  connect() {
    this.mark()
  }

  choose(event) {
    const theme = event.params.value
    if (theme !== "light" && theme !== "dark") return

    // Suppress transitions for a frame so switching doesn't animate every
    // colour on the page at once.
    document.documentElement.classList.add("theme-switching")
    document.documentElement.setAttribute("data-theme", theme)

    try {
      localStorage.setItem(this.constructor.storageKey, theme)
    } catch (e) {
      // Storage disabled: the theme still applies, it just won't persist.
    }

    this.mark()
    requestAnimationFrame(() => {
      document.documentElement.classList.remove("theme-switching")
    })
  }

  mark() {
    const current = document.documentElement.getAttribute("data-theme") || "light"

    this.optionTargets.forEach((option) => {
      const active = option.dataset.themeValueParam === current

      option.classList.toggle("text-ink", active)
      option.classList.toggle("font-semibold", active)
      option.classList.toggle("text-soft", !active)
      option.setAttribute("aria-pressed", active ? "true" : "false")
    })
  }
}
