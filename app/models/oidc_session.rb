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

  def self.create_for_user(oidc_sid:, session_id:, user_email:, expires_in: 24.hours)
    create!(
      oidc_sid: oidc_sid,
      session_id: session_id,
      user_email: user_email,
      expires_at: expires_in.from_now
    )
  rescue ActiveRecord::RecordNotUnique
    Rails.logger.warn "OIDC session already exists for sid: #{oidc_sid}"
    find_by(oidc_sid: oidc_sid)
  end

  # Expiring rather than deleting: the row is what a later request consults to
  # discover its session was revoked elsewhere, so it has to outlive the
  # logout by long enough to be found. cleanup_expired sweeps it later.
  def invalidate!
    update!(expires_at: 1.minute.ago)
  end
end
