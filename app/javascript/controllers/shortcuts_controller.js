import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

// Keyboard navigation: bare keys, the way Gmail and GitHub do it.
//
// What keeps a shortcut out of a reply is the field check — a key pressed with
// the caret in an input, a textarea, a select or anything contenteditable is
// the field's, never the page's. That used to be backed by a second guard,
// Shift, on the theory that a chord is safer than a list of elements to
// exclude. In practice the list is short and closed, the check already carried
// "/" on its own, and the chord cost every keystroke on every screen plus a
// double-tap latch mode whose only job was to get the bare keys back. So the
// keys are bare. Shift still works, for fingers that learned it.
//
// Mounted on <body>, so one controller serves every screen and each screen
// declares what it offers by which targets it renders: a list renders `row`
// targets and gets J/K/L, a ticket renders a `back` target and gets H — plus
// J/K through the list it was opened from, when there was one. A screen with
// neither is inert, and nothing needs to know which screen it is.
export default class extends Controller {
  static targets = ["row", "back", "hint", "search", "tickets", "step"]

  // All remembered per tab, not per browser: two tabs on two tickets should
  // not fight over one cursor.
  static selectionKey = "spool:selected-ticket"
  static originKey = "spool:ticket-origin"
  static legendKey = "spool:shortcut-legend"

  // ↑ and ↓ are deliberately absent. On a ticket they are how you read a long
  // thread, and a key that scrolls on one screen and leaves it on another is
  // worse than a key with one meaning. ← and → have no competing meaning —
  // nothing here scrolls sideways — so they take in and out.
  static keys = {
    j: "next",
    k: "previous",
    l: "open", enter: "open", arrowright: "open",
    h: "back", arrowleft: "back", escape: "back",
    t: "tickets",
    "/": "search",
    "?": "toggleLegend"
  }

  // What the keys do while the caret is still in the search box.
  //
  // The letters have to stay letters in there: J, K, L and H begin Jane, Kevin,
  // Lisa and Harry, which is exactly what someone searching for a person types.
  // So it is arrows to walk the results — in a single-line input ↑/↓ only jump
  // the caret to an end it is usually already at, and it is what every search
  // box in the world already does — and Enter to pick one.
  //
  // Enter with nothing picked, or Escape in an empty box, puts the box down:
  // you have asked your question, and the letters go back to being the list's.
  // (Escape in a box with something in it is the search controller's, and
  // clears it — clearing is not leaving.)
  static fieldKeys = {
    arrowdown: "next",
    arrowup: "previous",
    enter: "choose",
    escape: "putDown"
  }

  connect() {
    this.onKeyDown = this.handleKeyDown.bind(this)
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
    // A frame being replaced by a new request is exactly the moment, and
    // nothing else is: it is what asking a different question does. Coming
    // back from a ticket is a page visit, so it still lands on the row you left.
    //
    // turbo:before-frame-render, not turbo:frame-render. Turbo swaps the new
    // rows in and then waits a frame or two before announcing it has rendered;
    // clearing on the announcement undid any key pressed in between, on rows
    // already on screen. Cleared before the swap, the first key on the new rows
    // is the first key that counts.
    this.onBeforeFrameRender = () => this.clearSelection()

    // A refresh — new mail, another agent's change — morphs the page toward the
    // server's HTML, and the server renders the legend hidden: it has no idea
    // you put it up. Whether the legend and its items show is this controller's
    // to say, so the morph is told to leave that attribute alone.
    this.onBeforeMorphAttribute = (event) => {
      if (event.detail.attributeName === "hidden" && this.showsOwnVisibility(event.target)) {
        event.preventDefault()
      }
    }

    // On window rather than the element: the keys have to work before anything
    // on the page has been clicked, and an unfocused <body> receives nothing.
    window.addEventListener("keydown", this.onKeyDown)
    window.addEventListener("turbo:before-frame-render", this.onBeforeFrameRender)
    document.addEventListener("turbo:before-morph-attribute", this.onBeforeMorphAttribute)

    // The legend outlives a navigation on purpose: you open it to learn the
    // keys, and each screen answers to different ones.
    this.applyLegend(this.legendShown)
  }

  disconnect() {
    window.removeEventListener("keydown", this.onKeyDown)
    window.removeEventListener("turbo:before-frame-render", this.onBeforeFrameRender)
    document.removeEventListener("turbo:before-morph-attribute", this.onBeforeMorphAttribute)
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

  // The legend offers J/K on a ticket only when there is a list behind it. A
  // ticket opened cold has nowhere to step to, and a key the legend offers
  // that then does nothing reads as broken.
  stepTargetConnected(item) {
    item.hidden = this.stepList.length < 2
  }

  // "/" pressed away from the list: the visit is under way, and the box it was
  // for has just arrived.
  searchTargetConnected(field) {
    if (!this.constructor.searchOnArrival) return
    // A cached copy of the list is shown first while the real one loads, and
    // then thrown away — focus given to its box would go with it.
    if (document.documentElement.hasAttribute("data-turbo-preview")) return

    this.constructor.searchOnArrival = false
    field.focus()
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
    // answer for the ticket it was recorded for. See originFor(). The list is
    // the tickets on screen, in screen order — what J and K step through from
    // the ticket. People are left out: stepping is ticket to ticket.
    this.origin = {
      ticket: row.dataset.ticketId,
      url: window.location.pathname + window.location.search,
      list: this.rowTargets
        .filter((other) => other.dataset.ticketId)
        .map((other) => ({ id: other.dataset.ticketId, href: other.getAttribute("href") }))
    }
  }

  // J and K: the cursor on a list, the ticket itself on a ticket.
  next() {
    this.hasRowTarget ? this.move(1) : this.step(1)
  }

  previous() {
    this.hasRowTarget ? this.move(-1) : this.step(-1)
  }

  open() {
    // The click carries the row's own data-turbo-frame="_top", so the visit
    // behaves exactly as it does for the mouse.
    this.selectedRow?.click()
  }

  back() {
    Turbo.visit(this.originFor(this.backTarget)?.url || this.backTarget.href)
  }

  // Home, and deliberately not H's smarter cousin: T goes to the inbox as it
  // is, with no filter, no query and no memory of how you got anywhere. H
  // retraces a step; T is the way out of whatever you have narrowed yourself
  // into. On the list itself that makes it "clear everything", which is the
  // same gesture answering the same question.
  //
  // The header's nav link is the target, so this key exists exactly where that
  // link does — which is every screen — and nothing here has to know the route.
  tickets() {
    Turbo.visit(this.ticketsTarget.href)
  }

  // The box lives on the list. Anywhere else, "/" goes there with the caret
  // already in it — the same place T goes, which is the list as you left it.
  search() {
    if (this.hasSearchTarget) {
      this.searchTarget.focus()
      this.searchTarget.select()
    } else if (this.hasTicketsTarget) {
      // Static, so it outlives this instance: Turbo swaps <body> and the
      // controller that lands with the list is a new one.
      this.constructor.searchOnArrival = true
      Turbo.visit(this.ticketsTarget.href)
    }
  }

  choose() {
    this.selectedRow ? this.open() : this.putDown()
  }

  // The search controller asks any query still waiting out its debounce as
  // the box loses focus, so the answer is in before you start walking it.
  putDown() {
    this.searchTarget.blur()
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
  originFor(target) {
    const origin = this.origin
    if (!origin || !target.dataset.ticketId) return null

    return origin.ticket === target.dataset.ticketId ? origin : null
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

  // From a ticket to its neighbour in the list it was opened from. The list is
  // as it was when you opened the first one — a snapshot, not a live query —
  // so closing a ticket as you go doesn't pull the next one out from under
  // you. Clamped at the ends, like the cursor.
  step(delta) {
    const list = this.stepList
    const index = list.findIndex((ticket) => ticket.id === this.backTarget.dataset.ticketId)
    const next = index === -1 ? null : list[index + delta]
    if (!next) return

    // The memory moves with you, so H from wherever you stop still goes back
    // to the list you started from.
    this.origin = { ...this.origin, ticket: next.id }
    Turbo.visit(next.href)
  }

  get stepList() {
    if (!this.hasBackTarget) return []

    return this.originFor(this.backTarget)?.list || []
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

  // Keys ------------------------------------------------------------------

  handleKeyDown(event) {
    if (event.metaKey || event.ctrlKey || event.altKey) return

    // The node the key actually landed on. event.target stops at a shadow
    // root's host, so a field inside a web component would otherwise read as
    // not being a field at all.
    const target = event.composedPath()[0]

    // The search box is the one field the keys have to survive. You have just
    // asked a question and the answer is on screen under the caret; reaching it
    // shouldn't require first knowing how to put the box down.
    if (this.hasSearchTarget && target === this.searchTarget) {
      return this.handle(event, this.constructor.fieldKeys)
    }

    if (this.typing(target)) return

    // Enter on a link or a button is that control's, and it should do what
    // it says rather than open a row it isn't.
    if (event.key === "Enter" && this.activatable(target)) return

    this.handle(event, this.constructor.keys)
  }

  handle(event, keys) {
    // Something nearer the key already answered it — the search controller
    // clearing the box on Escape, say.
    if (event.defaultPrevented) return

    const action = keys[event.key.toLowerCase()]
    if (!action || !this.answers(action)) return

    event.preventDefault()
    this[action]()
  }

  // Whether this screen does anything with the action right now. A key that
  // would do nothing is left to the browser, so Enter still submits and
  // Escape still stops a page load.
  answers(action) {
    switch (action) {
      case "open": return !!this.selectedRow
      case "back": return this.hasBackTarget
      case "tickets": return this.hasTicketsTarget
      case "search": return this.hasSearchTarget || this.hasTicketsTarget
      case "toggleLegend": return this.hasHintTarget
      default: return true
    }
  }

  typing(node) {
    if (!node || !node.tagName) return false
    if (node.isContentEditable) return true

    return ["input", "textarea", "select"].includes(node.tagName.toLowerCase())
  }

  activatable(node) {
    return !!node?.closest?.("a[href], button, summary, [role='button'], [role='link']")
  }

  // The legend ------------------------------------------------------------

  toggleLegend() {
    this.applyLegend(!this.legendShown)
  }

  applyLegend(on) {
    this.legendShown = on
    if (this.hasHintTarget) this.hintTarget.hidden = !on
  }

  showsOwnVisibility(element) {
    return (this.hasHintTarget && element === this.hintTarget) || this.stepTargets.includes(element)
  }

  get legendShown() {
    return this.read(this.constructor.legendKey, "memoryLegend") === "on"
  }

  set legendShown(on) {
    this.write(this.constructor.legendKey, "memoryLegend", on ? "on" : "off")
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

  // {ticket, url, list} — where a given ticket was opened from, and the
  // tickets that list showed.
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
