# frozen_string_literal: true

require "zstd-ruby"

module Compression
  # Per-process cache of zstd dictionaries.
  #
  # Indexed by id for decode (the row names the dictionary it was written
  # with), and by kind for encode ("which dictionary should a new body use?").
  # Entries hold the raw bytes plus pre-built Zstd::CDict/DDict, since building
  # those per call is avoidable work.
  #
  # Dictionaries are immutable once written: training produces a new version
  # row, never an update. That's what makes caching by id safe forever — an
  # entry can't go stale, only be superseded.
  module DictStore
    Entry = Struct.new(:id, :kind, :version, :bytes, :cdict, :ddict)

    # How long the "current dictionary for this kind" answer is cached before
    # being re-read. Bounds how long a worker keeps writing with a superseded
    # dictionary after another process trains a new one — and, more importantly,
    # how long a worker that booted before any dictionary existed keeps caching
    # the "none" answer. Without a TTL that answer would stick until restart and
    # every row would stay plain-zstd forever.
    ACTIVE_TTL = 300 # seconds

    class << self
      def fetch(id)
        return nil if id.nil?
        by_id[id] ||= load_row(id)
      end

      # The dictionary new rows of this kind should be written with, or nil for
      # plain zstd. "Current" is simply the highest version for the kind —
      # promotion is an INSERT, so there is no active flag to get out of sync.
      def current_id(kind)
        entry = active_cache[kind.to_s]
        if entry.nil? || entry[:expires_at] <= monotonic_now
          value = Dictionary.where(kind: kind.to_s).maximum(:version)
          id = value && Dictionary.where(kind: kind.to_s, version: value).pick(:id)
          entry = {value: id || :none, expires_at: monotonic_now + ACTIVE_TTL}
          active_cache[kind.to_s] = entry
        end
        (entry[:value] == :none) ? nil : entry[:value]
      end

      # Called after training promotes a new dictionary, so the next write in
      # this process picks it up without waiting out the TTL.
      def invalidate_current(kind)
        active_cache.delete(kind.to_s)
      end

      def reset!
        @by_id = nil
        @active_cache = nil
      end

      private

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def by_id
        @by_id ||= Concurrent::Map.new
      end

      def active_cache
        @active_cache ||= Concurrent::Map.new
      end

      def load_row(id)
        row = Dictionary.find_by(id: id)
        return nil unless row
        Entry.new(row.id, row.kind, row.version, row.data,
          Zstd::CDict.new(row.data), Zstd::DDict.new(row.data))
      end
    end
  end
end
