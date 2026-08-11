# frozen_string_literal: true

require "test_helper"

class Compression::CodecTest < ActiveSupport::TestCase
  # zstd's magic number. Asserting the frame, not the absence of plaintext:
  # zstd stores incompressible input as a raw literal block, so a short body is
  # perfectly legible inside its own frame. Compression is not obfuscation.
  ZSTD_MAGIC = "\x28\xB5\x2F\xFD".b

  test "round-trips text with no dictionary" do
    text = "Hello,\n\nThe printer is on fire again.\n\n-- \nAda"

    blob = Compression::Codec.encode(text)

    assert_equal Encoding::BINARY, blob.encoding
    assert blob.start_with?(ZSTD_MAGIC), "expected a zstd frame"
    assert_equal text, Compression::Codec.decode(blob)
  end

  test "a long repetitive body actually shrinks" do
    text = ("The printer is on fire again.\n" * 200)

    blob = Compression::Codec.encode(text)

    assert_operator blob.bytesize, :<, text.bytesize / 10
    assert_equal text, Compression::Codec.decode(blob)
  end

  test "round-trips multibyte text as UTF-8" do
    text = "Problème de facturation — 日本語 — 🔥"

    decoded = Compression::Codec.decode(Compression::Codec.encode(text))

    assert_equal text, decoded
    assert_equal Encoding::UTF_8, decoded.encoding
  end

  test "nil in, nil out" do
    assert_nil Compression::Codec.encode(nil)
    assert_nil Compression::Codec.decode(nil)
  end

  test "invalid byte sequences are scrubbed rather than raising" do
    # A lone continuation byte: valid to store, not valid UTF-8 to display.
    blob = Compression::Codec.encode("caf\xE9 latte".b)

    assert_nothing_raised { Compression::Codec.decode(blob) }
    assert Compression::Codec.decode(blob).valid_encoding?
  end

  test "raises rather than silently mis-decoding when a dictionary is missing" do
    assert_raises(ArgumentError) { Compression::Codec.encode("x", dict_id: 999_999) }
    assert_raises(ArgumentError) { Compression::Codec.decode("x", dict_id: 999_999) }
  end

  test "a compressed column records the dictionary it was written with" do
    customer = Customer.create!(email: "dict@example.com")
    ticket = Ticket.create!(customer: customer, last_activity_at: Time.current)

    message = Message.create!(
      ticket: ticket, direction: "note", message_id: "<dict-test@spool.test>",
      body: "a note"
    )

    # Ships with no dictionary, so the row records that fact rather than
    # guessing later.
    assert_nil message.body_dictionary_id
    assert_equal "a note", message.reload.body
  end

  test "rows written before a dictionary existed stay readable after one is promoted" do
    customer = Customer.create!(email: "mixed@example.com")
    ticket = Ticket.create!(customer: customer, last_activity_at: Time.current)

    plain = Message.create!(ticket: ticket, direction: "note",
      message_id: "<plain@spool.test>", body: "written before")

    Dictionary.promote!(kind: :body, data: sample_dictionary, sample_count: 100)

    with_dict = Message.create!(ticket: ticket, direction: "note",
      message_id: "<withdict@spool.test>", body: "written after")

    assert_nil plain.reload.body_dictionary_id
    assert_not_nil with_dict.reload.body_dictionary_id

    # Both readable, side by side, from the same table.
    assert_equal "written before", plain.body
    assert_equal "written after", with_dict.body
  end

  test "promote! versions rather than mutating" do
    first = Dictionary.promote!(kind: :body, data: sample_dictionary)
    second = Dictionary.promote!(kind: :body, data: sample_dictionary)

    assert_equal 1, first.version
    assert_equal 2, second.version
    assert_equal second.id, Dictionary.current(:body).id
    assert_equal second.id, Compression::DictStore.current_id(:body)

    # The superseded dictionary is still there and still loadable, because rows
    # written with it must keep decoding forever.
    assert_equal first.id, Compression::DictStore.fetch(first.id).id
  end

  private

  # zstd-ruby exposes no training API (training shells out to the CLI — see
  # docs/compression.md), so the tests use a fixed byte string. A dictionary is
  # just bytes as far as the codec is concerned; what's exercised here is the
  # id plumbing, not the compression ratio.
  def sample_dictionary
    @sample_dictionary ||= Rails.root.join("test/fixtures/files/sample.dict").binread
  end
end
