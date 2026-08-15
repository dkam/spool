class MessagesController < ApplicationController
  # Composing writes the row and queues the send — compose! owns both, so this
  # action stays a thin translation of form params. The thread and the ticket
  # state are correct the moment an agent hits send; delivery happens
  # asynchronously off spool.outbound (see docs/outbound.md), and the thread
  # shows "Queued · not yet delivered" until Mailgun accepts it.
  def create
    @ticket = Ticket.find(params[:ticket_id])
    text = params[:body].to_s.strip
    note = params[:direction] == "note"

    if text.blank?
      return redirect_to ticket_path(@ticket, anchor: "compose"),
        alert: note ? "The note was empty." : "The reply was empty."
    end

    # Message.compose! is the only supported way to build an outbound row: it
    # owns the Spool-issued Message-ID that LoopGuard matches on, the threading
    # headers taken from the last *emailed* message, the JSON body envelope and
    # the state transition. See docs/ui-contract.md.
    @message = Message.compose!(
      ticket: @ticket,
      agent: current_agent,
      text: text,
      direction: note ? "note" : "outbound"
    )

    redirect_to ticket_path(@ticket, anchor: "message-#{@message.id}")
  end
end
