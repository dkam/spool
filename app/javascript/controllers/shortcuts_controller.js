import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

// Keyboard navigation, gated behind Shift the way Basecamp does it.
//
// Shift is the whole safety mechanism. No bare keypress does anything, so a
// shortcut can never be triggered by someone typing a reply — and the guard is
// a property of the chord rather than a list of elements to remember to
// exclude. Two ways to use it:
//
//   Hold Shift and press a key. Hold it for a moment and a legend appears
//   saying what the screen answers to; the keys work whether or not you wait.
//
//   Tap Shift twice to latch it. The keys then work unshifted until you press
//   Escape or click into a field, and the legend stays up saying so.
//
// The latch is what makes search navigable. After typing, the caret is in the
// search box and every shortcut is correctly suppressed — so without it there
// is no keyboard route from the box into the results you just asked for. Two
// taps blurs the box and hands the keys back.
//
// Mounted on <body>, so one controller serves every screen and each screen
// declares what it offers by which targets it renders: a list renders `row`
// targets and gets J/K/L, a ticket renders a `back` target and gets H. A
// screen with neither is inert, and nothing needs to know which screen it is.
export default class extends Controller {
  static targets = ["row", "back", "hint", "search", "latch"]

  // All remembered per tab, not per browser: two tabs on two tickets should
  // not fight over one cursor.
  static selectionKey = "spool:selected-ticket"
  static originKey = "spool:ticket-origin"
  static latchKey = "spool:shortcut-latch"

  // Long enough that shift-typing a capital never flashes the legend, short
  // enough that a deliberate hold feels answered.
  static hintDelay = 400

  // Press-to-press, not release-to-press, and generous with it.
  //
  // Both parts were wrong first time and the tests didn't catch either, because
  // Selenium fires two taps within a millisecond and a hand does not. A
  // deliberate tap of a modifier holds it for a beat, and the gap between two
  // of them is comfortably over 450ms — which is why the first version worked
  // in the suite and not for the person using it. Timing the way a double
  // click is timed, from press to press, is both the forgiving reading and the
  // one people already have in their fingers.
  //
  // Widening is close to free: what stops "HELLO" latching is that any other
  // key disarms the tap, not the length of the window.
  static doubleTapWindow = 750

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
    this.onFocusIn = this.handleFocusIn.bind(this)
    // Shift-click to extend a text selection releases Shift afterwards, which
    // would otherwise arm the second half of a double tap and let the next
    // stray Shift latch the mode. Taken from booko's controller, which guards
    // the same case.
    this.onPointerDown = () => { this.tapArmed = false }
    // A cursor belongs to a list. Ask a different question — a search, a filter
    // — and the answer is a different list, so the cursor starts at the top of
    // it rather than resuming from wherever you happened to be.
    //
    // Without this, the first J after a search lands somewhere that depends on
    // whether the ticket you were looking at minutes ago happens to have
    // survived the narrowing: usually the top, but silently not when it did.
    // Searching a person is where that reads worst, because the row it skips is
    // the People section — the thing you searched for.
    //
    // turbo:frame-render is exactly the event, and nothing else is: it fires
    // when a frame is replaced by a new request, which is what asking a
    // different question does. Coming back from a ticket is a page visit, so it
    // still lands on the row you left.
    this.onFrameRender = () => this.clearSelection()

    // On window rather than the element: the keys have to work before anything
    // on the page has been clicked, and an unfocused <body> receives nothing.
    window.addEventListener("keydown", this.onKeyDown)
    window.addEventListener("keyup", this.onKeyUp)
    // Shift's keyup never arrives if the window loses focus mid-hold, which
    // would strand the legend on screen until the next keypress.
    window.addEventListener("blur", this.onBlur)
    // Clicking into any field means you are typing again, whatever the latch
    // thought. Unlatching there rather than only on Escape means the mode can
    // never be the reason a keystroke went missing from a reply.
    window.addEventListener("focusin", this.onFocusIn)
    window.addEventListener("pointerdown", this.onPointerDown)
    window.addEventListener("turbo:frame-render", this.onFrameRender)

    // The latch outlives a navigation on purpose: latch, walk the list, open a
    // ticket, come back — the mode you turned on is still on. It is a mode, so
    // it stays until you leave it, and the legend is on screen the whole time.
    this.applyLatch(this.latched)
  }

  disconnect() {
    window.removeEventListener("keydown", this.onKeyDown)
    window.removeEventListener("keyup", this.onKeyUp)
    window.removeEventListener("blur", this.onBlur)
    window.removeEventListener("focusin", this.onFocusIn)
    window.removeEventListener("pointerdown", this.onPointerDown)
    window.removeEventListener("turbo:frame-render", this.onFrameRender)
    clearTimeout(this.hintTimer)
    this.hintTimer = null
  }

  handleFocusIn(event) {
    if (this.latched && this.typing(event.target)) this.unlatch()
  }

  // Rows arrive and leave whenever the ticket_list frame re-renders, so the
  // highlight is restored per row as each one appears rather than in connect.
  // A filter that hides the remembered ticket simply shows no highlight; the
  // memory survives for when it comes back.
  rowTargetConnected(row) {
    if (row.dataset.rowId && row.dataset.rowId === this.selectedId) {
      row.dataset.selected = ""
    }
  }

  // Arriving at a ticket — by key, by click, or by pasted URL — makes it the
  // remembered row, so H always lands you back where you were looking.
  backTargetConnected(link) {
    if (link.dataset.rowId) this.selectedId = link.dataset.rowId
  }

  // Clicking a row has to leave the same trail as opening it from the
  // keyboard, or a mouse user who then presses H loses their filter.
  enter(event) {
    const row = event.currentTarget
    this.select(row)

    // Only tickets have a list to go back to. A person row leads to
    // customers/show, which offers no H, so recording an origin for it would
    // be storing an answer to a question that screen never asks.
    if (!row.dataset.ticketId) return

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
    this.selectedId = row.dataset.rowId
    row.scrollIntoView({ block: "nearest" })
  }

  get selectedRow() {
    const id = this.selectedId
    if (!id) return null

    return this.rowTargets.find((row) => row.dataset.rowId === id) || null
  }

  // The surviving row is already marked by the time a frame finishes rendering
  // — rowTargetConnected runs first — so forgetting the id is not enough.
  clearSelection() {
    this.rowTargets.forEach((row) => delete row.dataset.selected)
    this.selectedId = ""
  }

  // The legend ------------------------------------------------------------

  handleKeyDown(event) {
    if (event.key === "Shift") return this.handleShiftDown(event)

    // Any other key ends a candidate double-tap. Without this, typing "HELLO"
    // — shift, letter, shift, letter — would latch the mode mid-word.
    this.tapArmed = false

    if (event.metaKey || event.ctrlKey || event.altKey) return

    // Escape is how you get out, and it has to work from inside the search box
    // too, which is the one place the typing guard below would swallow it.
    if (event.key === "Escape" && this.latched) {
      this.unlatch()
      return
    }

    if (this.typing(event.target)) return

    // The search key, accepted both shifted and not.
    //
    // They are the same physical key: unshifted it types "/", and held with
    // Shift — the gesture every other shortcut here uses — it types "?". Taking
    // only one would mean the key worked or didn't depending on a finger that
    // makes no difference to anything else on the screen. So both.
    //
    // "/" alone is the one unshifted shortcut in here and a deliberate
    // exception: Shift gates the rest to keep them away from someone typing,
    // which the field check above already handles for this one. Being wrong
    // costs a focused search box and an Escape. "?" is free because the
    // shortcut legend appears on a held Shift rather than on a help key.
    if ((event.key === "/" || event.key === "?") && this.hasSearchTarget) {
      event.preventDefault()
      this.searchTarget.focus()
      this.searchTarget.select()
      return
    }

    // Shift, or the latch standing in for it. Shift+Cmd+L is the browser's.
    if (!event.shiftKey && !this.latched) return

    const action = this.constructor.keys[event.key.toLowerCase()]
    if (!action) return

    event.preventDefault()
    this[action]()
  }

  handleKeyUp(event) {
    if (event.key !== "Shift") return

    // Arms the second half of a double tap: a press only counts as the second
    // one if the first was actually released.
    this.tapArmed = true

    if (!this.latched) this.hideHint()
  }

  // The latch ---------------------------------------------------------------

  handleShiftDown(event) {
    // Auto-repeat while the key is held is not a second tap.
    if (event.repeat) return

    const now = Date.now()
    // tapArmed means a release happened since the last press, so a hold can't
    // masquerade as two taps; the window then measures press to press.
    const doubled = this.tapArmed && now - this.lastShiftDown < this.constructor.doubleTapWindow

    this.lastShiftDown = now
    this.tapArmed = false

    if (!doubled) return this.scheduleHint(event)

    this.latched ? this.unlatch() : this.latch()
  }

  latch() {
    this.applyLatch(true)

    // The reason the latch exists: after typing a search the caret is in the
    // box, and letting go of it is the thing you cannot otherwise do without
    // reaching for the mouse.
    if (this.typing(document.activeElement)) document.activeElement.blur()
  }

  unlatch() {
    this.applyLatch(false)
  }

  applyLatch(on) {
    this.latched = on
    if (this.hasLatchTarget) this.latchTarget.hidden = !on
    if (!this.hasHintTarget) return

    // Latched, the legend is not a hint any more — it is the only thing on
    // screen saying why bare keys are moving the page, so it stays up and says
    // how to stop.
    this.hintTarget.hidden = !on
    this.hintTarget.toggleAttribute("data-latched", on)
  }

  get latched() {
    return this.read(this.constructor.latchKey, "memoryLatched") === "on"
  }

  set latched(on) {
    this.write(this.constructor.latchKey, "memoryLatched", on ? "on" : "off")
  }

  scheduleHint(event) {
    if (!this.hasHintTarget || this.hintTimer || this.latched) return
    if (event.metaKey || event.ctrlKey || event.altKey) return
    if (this.typing(event.target)) return

    this.hintTimer = setTimeout(() => {
      this.hintTarget.hidden = false
    }, this.constructor.hintDelay)
  }

  hideHint() {
    clearTimeout(this.hintTimer)
    this.hintTimer = null
    if (this.hasHintTarget && !this.latched) this.hintTarget.hidden = true
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
