class OidcSession < ApplicationRecord
  validates :oidc_sid, presence: true, uniqueness: true
  validates :session_id, presence: true
  validates :user_email, presence: true
  validates :expires_at, presence: true

  scope :live, -> { where(expires_at: Time.current..) }

  def self.cleanup_expired
    where(expires_at: ...Time.current).delete_all
  end

  def self.find_live(sid)
    live.find_by(oidc_sid: sid)
  end

  def self.live_for_email(email)
    live.where(user_email: email)
  end

  # Creates the sid's mapping, or takes over the old one. The provider keeps one
  # sid for as long as you're signed in there, so a login after the mapping
  # expired, or after a backchannel logout invalidated it, brings the same sid
  # back — and it has just come with a verified ID token, so the provider holds
  # it live. A second row would fail uniqueness, the caller would swallow that,
  # and the next page would find no live mapping and log you straight back out.
  #
  # Wraps itself in the writing role, for the same reason TicketRead.mark_read!
  # does: the only caller is start_new_session_for, reached from the OIDC
  # callback — a GET, routed to the read-only replica. The caller's rescue would
  # have swallowed a ReadOnlyError here and logged a mapping failure, leaving
  # backchannel logout quietly broken rather than failing the login.
  def self.create_for_user(oidc_sid:, session_id:, user_email:, expires_in: 24.hours)
    ApplicationRecord.writing do
      mapping = find_or_initialize_by(oidc_sid: oidc_sid)
      mapping.update!(session_id: session_id, user_email: user_email, expires_at: expires_in.from_now)
      mapping
    end
  rescue ActiveRecord::RecordNotUnique
    # A concurrent login for the same sid inserted first; take its row over.
    retry
  end

  # Expiring rather than deleting: the row is what a later request consults to
  # discover its session was revoked elsewhere, so it has to outlive the
  # logout by long enough to be found. cleanup_expired sweeps it later.
  def invalidate!
    update!(expires_at: 1.minute.ago)
  end
end
