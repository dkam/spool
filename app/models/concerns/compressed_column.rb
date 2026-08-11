# frozen_string_literal: true

# Gives a model a plain text attribute backed by a zstd-compressed BLOB column
# and a sibling dictionary-id column:
#
#   compressed_column :body, kind: :body
#
# defines #body and #body= over `body_blob` and `body_dictionary_id`. The rest
# of the application only ever sees the string.
#
# Why a concern rather than the `attribute :body_blob, ZstdText.new` shape the
# build spec sketched: an ActiveRecord::Type only receives the column value, not
# the row, so a type cannot read the sibling `body_dictionary_id` to know which
# dictionary the row was written with. Storing the id inside the blob instead
# would duplicate the column and let the two disagree. The encapsulation the
# spec actually asked for — nothing outside this file touching zstd — holds
# either way.
module CompressedColumn
  extend ActiveSupport::Concern

  class_methods do
    def compressed_column(name, kind:)
      blob_column = :"#{name}_blob"
      dict_column = :"#{name}_dictionary_id"

      define_method(name) do
        # Memoised per instance: rendering a thread reads every body once for
        # display and, for the newest message, again to build a quote block.
        return @__compressed[name] if defined?(@__compressed) && @__compressed&.key?(name)

        value = Compression::Codec.decode(self[blob_column], dict_id: self[dict_column])
        (@__compressed ||= {})[name] = value
      end

      define_method(:"#{name}=") do |text|
        (@__compressed ||= {})[name] = text

        if text.nil?
          self[blob_column] = nil
          self[dict_column] = nil
        else
          # Resolved at write time, not read time: the row records the
          # dictionary it was actually compressed with, and later training can
          # never invalidate it.
          dict_id = Compression::DictStore.current_id(kind)
          self[blob_column] = Compression::Codec.encode(text, dict_id: dict_id)
          self[dict_column] = dict_id
        end

        text
      end
    end
  end

  # Drop the decoded cache when the record is reloaded, so a reload genuinely
  # re-reads rather than handing back the pre-reload string.
  def reload(*)
    @__compressed = nil
    super
  end
end
