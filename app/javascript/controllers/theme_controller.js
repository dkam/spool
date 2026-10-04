import { Controller } from "@hotwired/stimulus"

// Light/dark switching.
//
// The system's setting is the default, and there is no "System" button for
// it: a choice is only remembered while it differs from the system. Pick the
// theme the system would have given you anyway and the choice is forgotten,
// so Spool follows the system again — including when it flips at sunset.
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
    this.system = window.matchMedia("(prefers-color-scheme: dark)")
    // Without a choice of its own, the page follows; with one, only the
    // tooltip naming the system's setting needs to change.
    this.systemChanged = () => {
      if (this.stored()) this.mark()
      else this.apply(this.systemTheme())
    }
    this.system.addEventListener("change", this.systemChanged)

    this.mark()
  }

  disconnect() {
    this.system.removeEventListener("change", this.systemChanged)
  }

  choose(event) {
    const theme = event.params.value
    if (theme !== "light" && theme !== "dark") return

    try {
      if (theme === this.systemTheme()) {
        localStorage.removeItem(this.constructor.storageKey)
      } else {
        localStorage.setItem(this.constructor.storageKey, theme)
      }
    } catch (e) {
      // Storage disabled: the theme still applies, it just won't persist.
    }

    this.apply(theme)
  }

  apply(theme) {
    // Suppress transitions for a frame so switching doesn't animate every
    // colour on the page at once.
    document.documentElement.classList.add("theme-switching")
    document.documentElement.setAttribute("data-theme", theme)

    this.mark()
    requestAnimationFrame(() => {
      document.documentElement.classList.remove("theme-switching")
    })
  }

  mark() {
    const current = document.documentElement.getAttribute("data-theme") || "light"
    const title = this.stored()
      ? `Picked here. Your system is ${this.systemTheme()} — choose that to follow it again.`
      : "Following your system's setting."

    this.optionTargets.forEach((option) => {
      const active = option.dataset.themeValueParam === current

      option.classList.toggle("text-ink", active)
      option.classList.toggle("font-semibold", active)
      option.classList.toggle("text-soft", !active)
      option.setAttribute("aria-pressed", active ? "true" : "false")
      option.title = title
    })
  }

  systemTheme() {
    return this.system.matches ? "dark" : "light"
  }

  stored() {
    try {
      const theme = localStorage.getItem(this.constructor.storageKey)
      return theme === "light" || theme === "dark" ? theme : null
    } catch (e) {
      return null
    }
  }
}
