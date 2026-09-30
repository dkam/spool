# frozen_string_literal: true

require "test_helper"
require "rake"

class MessagesRakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("messages:reexcerpt")
  end

  # A message ingested under an older excerpt rule keeps what that rule made.
  test "reexcerpt rewrites a stale excerpt from the stored body, and search follows" do
    raw = file_fixture("emails/dashed_dividers.eml").read
    message = Ingest::Inbound.ingest(raw, source: "test").message
    message.update_columns(body_excerpt: "A User has created an issue")

    assert_output(/Recomputed 1 excerpt/) { Rake::Task["messages:reexcerpt"].execute }

    assert_includes message.reload.body_excerpt, "Image of DVD is missing"
    assert_includes Message.search("DVD").map(&:id), message.id
  end

  test "reexcerpt leaves a current excerpt alone" do
    Ingest::Inbound.ingest(file_fixture("emails/new_ticket.eml").read, source: "test")

    assert_output(/Recomputed 0 excerpt/) { Rake::Task["messages:reexcerpt"].execute }
  end
end
