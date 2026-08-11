# frozen_string_literal: true

require "test_helper"

# Guards the seam between "building the image" and "starting the app".
#
# Three separate boot-time checks each independently made this app impossible to
# containerise, and all three were invisible until someone ran `docker build`:
# nothing else ever boots in RAILS_ENV=production. They failed at
# assets:precompile, which boots production deliberately without any runtime
# configuration.
#
# The rule that resolves it: a check that guards *serving traffic* must not fire
# while *compiling assets*. SECRET_KEY_BASE_DUMMY is the signal Rails itself
# sets to mean "this boot will never serve a request", so it is the condition
# used, and these tests pin both halves — the exemption exists, and it is narrow.
class BuildBootTest < ActiveSupport::TestCase
  # Comments explain the flag; only executable lines can widen the exemption.
  def code_in(path)
    Rails.root.join(path).read.lines.reject { |l| l.strip.start_with?("#") }.join
  end

  test "application.rb only waives SECRET_KEY_BASE for a dummy build" do
    source = code_in("config/application.rb")

    assert_match(/Rails\.env\.production\? && ENV\["SECRET_KEY_BASE_DUMMY"\]\.blank\?/, source,
      "the waiver must be conjoined with production, not replace the production check")
  end

  test "the auth config check waives itself only for a dummy build" do
    source = code_in("config/initializers/auth_config_check.rb")

    assert_match(/next if ENV\["SECRET_KEY_BASE_DUMMY"\]\.present\?/, source)
    # If this ever grows a second condition, that is a widening of the one case
    # where an unauthenticated production boot is tolerated, and it needs
    # saying out loud rather than slipping in.
    assert_equal 1, source.scan("SECRET_KEY_BASE_DUMMY").size,
      "exactly one build-time exemption, or the guard is being widened"
  end

  test "production does not configure gems that are not in the Gemfile" do
    source = code_in("config/environments/production.rb")
    gemfile = Rails.root.join("Gemfile").read

    # solid_queue was the specific case: left over from the Rails template,
    # removed from the Gemfile in favour of tuber, and it raised NoMethodError
    # the first time production booted. Nothing but a container build would
    # have found it.
    %w[solid_queue active_storage action_mailbox action_text].each do |absent|
      next if gemfile.include?(absent)

      refute_match(/^\s*config\.#{absent}[.\s]/, source,
        "production.rb configures #{absent}, which is not in the Gemfile — production will not boot")
    end
  end
end
