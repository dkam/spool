# frozen_string_literal: true

# Stands in for a reserved Tuber::Job in consumer tests: records what the
# consumer did with it. `releases` is how many times tuber says it has already
# been released, which is what the consumer counts retries by.
class FakeTuberJob
  Stats = Struct.new(:releases)

  attr_reader :body, :outcome

  def initialize(body, releases: 0)
    @body = body.is_a?(String) ? body : JSON.generate(body)
    @releases = releases
  end

  def stats = Stats.new(@releases)

  def delete = @outcome = :deleted

  def release(delay: 0) = @outcome = :released

  def bury = @outcome = :buried

  def touch = nil

  def id = 1
end
