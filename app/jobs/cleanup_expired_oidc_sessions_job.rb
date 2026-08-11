# Plain class, not an ActiveJob: it's dispatched by name from
# config/schedule.yml through Ingest::DispatchConsumer, which needs no
# serialisation contract.
class CleanupExpiredOidcSessionsJob
  def perform
    count = OidcSession.cleanup_expired
    Rails.logger.info "Cleaned up #{count} expired OIDC session mappings"
    count
  end
end
