class MessagesController < ApplicationController
  # Composing writes a row; nothing delivers it yet (milestone 5 — see
  # docs/architecture.md). The thread and the ticket state are correct the
  # moment an agent hits send, so delivery is the one piece still missing rather
  # than the whole path being stubbed. When it lands it hooks onto compose!, and
  # this action does not change.
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
