# frozen_string_literal: true

require "zstd-ruby"

module Compression
  # Compresses and decompresses message header and body text.
  #
  # dict_id nil means plain zstd with no dictionary — which is how Spool ships
  # and how it stays until the corpus is large enough to train against. See
  # docs/compression.md.
  module Codec
    LEVEL = 3

    module_function

    def encode(text, dict_id: nil)
      return nil if text.nil?

      # Force binary before compressing. zstd works on bytes, and a UTF-8
      # string round-tripped through a BLOB column comes back ASCII-8BIT
      # anyway; being explicit keeps encode/decode symmetric.
      bytes = text.to_s.dup.force_encoding(Encoding::BINARY)

      if dict_id
        entry = DictStore.fetch(dict_id) or
          raise ArgumentError, "Compression::Codec.encode: dictionary #{dict_id} not found"
        Zstd.compress(bytes, level: LEVEL, dict: entry.cdict)
      else
        Zstd.compress(bytes, level: LEVEL)
      end
    end

    def decode(blob, dict_id: nil)
      return nil if blob.nil?

      raw =
        if dict_id
          entry = DictStore.fetch(dict_id) or
            raise ArgumentError, "Compression::Codec.decode: dictionary #{dict_id} not found"
          Zstd.decompress(blob, dict: entry.ddict)
        else
          Zstd.decompress(blob)
        end

      # Everything stored through this codec is text (a MIME header block or a
      # message body), so hand it back as UTF-8 rather than raw bytes. scrub
      # because a mail body can legitimately contain sequences that aren't
      # valid UTF-8 once the transfer encoding is undone, and a helpdesk should
      # render those as replacement characters rather than raise on display.
      raw.force_encoding(Encoding::UTF_8).scrub
    end
  end
end
