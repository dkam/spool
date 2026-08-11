class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  # Reads go to a second connection pool against the same SQLite file (see
  # config/database.yml). In test there is no replica role: the suite runs
  # inside an uncommitted transaction on the writer connection, and a genuinely
  # separate connection would see an empty database.
  if Rails.env.test?
    connects_to database: {writing: :primary, reading: :primary}
  else
    connects_to database: {writing: :primary, reading: :primary_replica}
  end

  # Switches to the writing role for the duration of the block.
  #
  # Needed in two places: background jobs, which run outside the
  # DatabaseSelector middleware and so default to reading; and the handful of
  # legitimate writes on a GET (marking a ticket read, provisioning the
  # open-mode agent), which the middleware has routed to reading.
  #
  # `ActiveRecord::Base.connected_to`, deliberately, NOT `connected_to` on self.
  # `prevent_writes` is tracked per connection class. The middleware sets it on
  # ActiveRecord::Base, so clearing it on ApplicationRecord leaves the flag the
  # adapter actually consults still true — the write raises ReadOnlyError while
  # `ApplicationRecord.current_preventing_writes` cheerfully reports false.
  #
  # This is invisible in development and production, where the two roles are
  # separate pools and switching role moves to a connection that was never
  # marked read-only — the role switch carries the write, not the flag. It is
  # only visible in test, where both roles point at one pool (see the
  # connects_to above) and the flag is therefore the only thing deciding.
  # Getting it right here means the wrap behaves identically in all three.
  def self.writing(&block)
    ActiveRecord::Base.connected_to(role: :writing, &block)
  end
end
