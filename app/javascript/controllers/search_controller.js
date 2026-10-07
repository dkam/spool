import { Controller } from "@hotwired/stimulus"

// Search-as-you-type, in the page rather than in a dropdown.
//
// The results are the ticket list itself — search is a `?q=` narrowing of that
// list, not a screen of its own — so typing refreshes the ticket_list frame and
// leaves everything around it, including this box and the caret in it, exactly
// where it was. The frame's own data-turbo-action="advance" keeps the address
// bar in step, so every state you type through stays linkable and the back
// button still means something. None of that is true of a dropdown.
export default class extends Controller {
  static targets = ["field"]

  // Long enough that a typed word is one query rather than five, short enough
  // that the list feels like it is keeping up.
  static delay = 220

  disconnect() {
    this.cancel()
  }

  schedule() {
    this.cancel()
    this.timer = setTimeout(() => this.submit(), this.constructor.delay)
  }

  // Putting the box down means the question is finished, so one still waiting
  // out the debounce is asked now. Left to the timer it would land a moment
  // later — after the arrows or J have started walking the results — and the
  // new list would reset the cursor. With nothing pending there is nothing to
  // ask: the results on screen already answer what is in the box.
  flush() {
    if (this.timer) this.submit()
  }

  submit() {
    this.cancel()
    this.element.requestSubmit()
  }

  cancel() {
    clearTimeout(this.timer)
    this.timer = null
  }

  // Escape empties the box and searches for nothing, which is how you get back
  // to the unfiltered list — the search IS the state, so clearing it is the
  // whole gesture. requestSubmit rather than submit, so Turbo sees it.
  clear(event) {
    if (!this.hasFieldTarget || this.fieldTarget.value === "") return

    event.preventDefault()
    this.cancel()
    this.fieldTarget.value = ""

    // Submitted with the field un-named so it isn't serialised at all, which
    // leaves `/tickets` rather than `/tickets?q=`. Cosmetic anywhere else;
    // here the frame advances the address bar, so that empty parameter would
    // be pushed into history and copied out of the URL bar by anyone sharing
    // the list. The hidden filter fields still submit, so clearing a search
    // keeps the filters you were in.
    //
    // Restored immediately: Turbo serialises the form inside the submit event,
    // which requestSubmit dispatches synchronously.
    const name = this.fieldTarget.name
    this.fieldTarget.name = ""
    this.element.requestSubmit()
    this.fieldTarget.name = name
  }
}
