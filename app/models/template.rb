class Template < ApplicationRecord
  validates :name, presence: true

  scope :alphabetical, -> { order(:name) }

  # Interpolated into the compose box for the agent to edit. Never auto-sent,
  # so an unresolved placeholder is a visible typo rather than something a
  # customer receives.
  #
  # Deliberately not ERB: templates are user-editable content, and evaluating
  # arbitrary Ruby from a database row is not a feature.
  PLACEHOLDER = /\{\{\s*([a-z_]+)\.([a-z_]+)\s*\}\}/

  def render(customer:, agent:)
    context = {
      "customer" => {"name" => customer&.display_name, "email" => customer&.email},
      "agent" => {"name" => agent&.display_name, "email" => agent&.email}
    }

    {
      subject: interpolate(subject, context),
      body: interpolate(body, context)
    }
  end

  private

  def interpolate(text, context)
    text.to_s.gsub(PLACEHOLDER) do
      # An unknown placeholder is left exactly as written rather than blanked:
      # the agent can see what went wrong before they send.
      context.dig(Regexp.last_match(1), Regexp.last_match(2)) || Regexp.last_match(0)
    end
  end
end
