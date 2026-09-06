class DashboardController < ApplicationController
  SHOWN = 6

  def show
    @recent_events = Event.reorder(id: :desc).limit(5)

    # What the operator came here for. The list is short on purpose — this page
    # is a glance, and the passports page is the place to work.
    @passports = Passport.reorder(updated_at: :desc).limit(SHOWN)
    @passport_count = Passport.count

    # A mandate that runs out unnoticed is the failure this page exists to
    # prevent: the passport stays readable, so nothing looks wrong until
    # somebody tries to correct or end it. Nobody opens every passport to check
    # a date, so the ones that need a signature are named here.
    @mandates_due = Passport.where.not(delegation_expires_at: nil)
                            .where(delegation_expires_at: ..(Time.current + Did::Delegation::RENEW_WITHIN))
                            .where(retired_at: nil)
  end
end
