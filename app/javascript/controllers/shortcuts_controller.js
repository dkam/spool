import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

// Keyboard navigation, gated behind a held Shift the way Basecamp does it.
//
// Shift is the whole safety mechanism. Nothing here fires from a bare
// keypress, so a shortcut can never be triggered by someone typing a reply —
// and the guard is a property of the design rather than a list of elements to
// remember to exclude. Hold Shift for a moment and a legend appears; the keys
// work immediately either way, the legend is only for people who haven't
// learned them yet.
//
// Mounted on <body>, so one controller serves every screen and each screen
// declares what it offers by which targets it renders: a list renders `row`
// targets and gets J/K/L, a ticket renders a `back` target and gets H. A
// screen with neither is inert, and nothing needs to know which screen it is.
export default class extends Controller {
  static targets = ["row", "back", "hint"]

  // Both remembered per tab, not per browser: two tabs on two tickets should
  // not fight over one cursor.
  static selectionKey = "spool:selected-ticket"
  static originKey = "spool:ticket-origin"

  // Long enough that shift-typing a capital never flashes the legend, short
  // enough that a deliberate hold feels answered.
  static hintDelay = 400

  static keys = {
    j: "next", arrowdown: "next",
    k: "previous", arrowup: "previous",
    l: "open", arrowright: "open",
    h: "back", arrowleft: "back"
  }

  connect() {
    this.onKeyDown = this.handleKeyDown.bind(this)
    this.onKeyUp = this.handleKeyUp.bind(this)
    this.onBlur = this.hideHint.bind(this)

    // On window rather than the element: the keys have to work before anything
    // on the page has been clicked, and an unfocused <body> receives nothing.
    window.addEventListener("keydown", this.onKeyDown)
    window.addEventListener("keyup", this.onKeyUp)
    // Shift's keyup never arrives if the window loses focus mid-hold, which
    // would strand the legend on screen until the next keypress.
    window.addEventListener("blur", this.onBlur)
  }

  disconnect() {
    window.removeEventListener("keydown", this.onKeyDown)
    window.removeEventListener("keyup", this.onKeyUp)
    window.removeEventListener("blur", this.onBlur)
    this.hideHint()
  }

  // Rows arrive and leave whenever the ticket_list frame re-renders, so the
  // highlight is restored per row as each one appears rather than in connect.
  // A filter that hides the remembered ticket simply shows no highlight; the
  // memory survives for when it comes back.
  rowTargetConnected(row) {
    if (row.dataset.ticketId && row.dataset.ticketId === this.selectedId) {
      row.dataset.selected = ""
    }
  }

  // Arriving at a ticket — by key, by click, or by pasted URL — makes it the
  // remembered row, so H always lands you back where you were looking.
  backTargetConnected(link) {
    if (link.dataset.ticketId) this.selectedId = link.dataset.ticketId
  }

  // Clicking a row has to leave the same trail as opening it from the
  // keyboard, or a mouse user who then presses H loses their filter.
  enter(event) {
    const row = event.currentTarget
    this.select(row)

    // Paired with the ticket rather than stored loose, so it can only ever
    // answer for the ticket it was recorded for. See back().
    this.origin = {
      ticket: row.dataset.ticketId,
      url: window.location.pathname + window.location.search
    }
  }

  next() {
    this.move(1)
  }

  previous() {
    this.move(-1)
  }

  open() {
    // The click carries the row's own data-turbo-frame="_top", so the visit
    // behaves exactly as it does for the mouse.
    this.selectedRow?.click()
  }

  back() {
    if (!this.hasBackTarget) return

    Turbo.visit(this.originUrlFor(this.backTarget) || this.backTarget.href)
  }

  // The list this screen was actually opened from, or nothing.
  //
  // The pairing is the whole point. A loose "last list I was on" is wrong in
  // two directions: it never lets the breadcrumb fallback fire, so a ticket
  // opened cold from a pasted URL goes back to a list it has no relationship
  // with; and on a screen that lists tickets itself, the last list is that
  // screen, so H would visit the page it is already on — a key that looks
  // broken rather than one that is absent. Matching on the ticket makes the
  // memory answer only for the ticket it was recorded for, and fall silent
  // otherwise, which is exactly when the breadcrumb is the better answer.
  originUrlFor(target) {
    const origin = this.origin
    if (!origin || !target.dataset.ticketId) return null

    return origin.ticket === target.dataset.ticketId ? origin.url : null
  }

  // Navigation ------------------------------------------------------------

  move(delta) {
    const rows = this.rowTargets
    if (rows.length === 0) return

    const current = rows.indexOf(this.selectedRow)
    // Clamped, not wrapped: falling off the end of the inbox and reappearing
    // at the top reads as a glitch rather than as a loop.
    const next = current === -1
      ? (delta > 0 ? 0 : rows.length - 1)
      : Math.min(rows.length - 1, Math.max(0, current + delta))

    this.select(rows[next])
  }

  select(row) {
    this.rowTargets.forEach((other) => delete other.dataset.selected)

    row.dataset.selected = ""
    this.selectedId = row.dataset.ticketId
    row.scrollIntoView({ block: "nearest" })
  }

  get selectedRow() {
    const id = this.selectedId
    return this.rowTargets.find((row) => row.dataset.ticketId === id) || null
  }

  // The legend ------------------------------------------------------------

  handleKeyDown(event) {
    if (event.key === "Shift") return this.scheduleHint(event)

    // Shift and nothing else. Shift+Cmd+L is the browser's, not ours.
    if (!event.shiftKey || event.metaKey || event.ctrlKey || event.altKey) return
    if (this.typing(event.target)) return

    const action = this.constructor.keys[event.key.toLowerCase()]
    if (!action) return

    event.preventDefault()
    this[action]()
  }

  handleKeyUp(event) {
    if (event.key === "Shift") this.hideHint()
  }

  scheduleHint(event) {
    if (!this.hasHintTarget || this.hintTimer) return
    if (event.metaKey || event.ctrlKey || event.altKey) return
    if (this.typing(event.target)) return

    this.hintTimer = setTimeout(() => {
      this.hintTarget.hidden = false
    }, this.constructor.hintDelay)
  }

  hideHint() {
    clearTimeout(this.hintTimer)
    this.hintTimer = null
    if (this.hasHintTarget) this.hintTarget.hidden = true
  }

  typing(node) {
    if (!node || !node.tagName) return false
    if (node.isContentEditable) return true

    return ["input", "textarea", "select"].includes(node.tagName.toLowerCase())
  }

  // Storage ---------------------------------------------------------------
  //
  // sessionStorage can throw outright in private browsing, and losing the
  // cursor is not worth breaking the keys over — memory carries it for the
  // life of the page instead.

  get selectedId() {
    return this.read(this.constructor.selectionKey, "memorySelectedId")
  }

  set selectedId(value) {
    this.write(this.constructor.selectionKey, "memorySelectedId", value)
  }

  // {ticket, url} — where a given ticket was opened from.
  get origin() {
    try {
      return JSON.parse(this.read(this.constructor.originKey, "memoryOrigin"))
    } catch (e) {
      // Absent, or left over in an older shape by a previous deploy.
      return null
    }
  }

  set origin(value) {
    this.write(this.constructor.originKey, "memoryOrigin", JSON.stringify(value))
  }

  read(key, fallback) {
    try {
      return sessionStorage.getItem(key)
    } catch (e) {
      return this.constructor[fallback] || null
    }
  }

  write(key, fallback, value) {
    // Static, so it outlives the controller instance that Turbo throws away
    // on every navigation.
    this.constructor[fallback] = value

    try {
      sessionStorage.setItem(key, value)
    } catch (e) {
      // Storage disabled — the fallback above is the whole memory.
    }
  }
}
