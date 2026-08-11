import { Controller } from "@hotwired/stimulus"

// Submits the form a control belongs to when that control changes — used by
// the assignee select, which has no submit button of its own because the
// design's action row is a row of words, not a form.
//
// requestSubmit rather than submit: it fires the submit event, which is what
// Turbo listens for. Calling .submit() would bypass Turbo and full-page reload.
export default class extends Controller {
  submit() {
    this.element.requestSubmit()
  }
}
