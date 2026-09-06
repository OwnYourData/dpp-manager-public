class DashboardController < ApplicationController
  def show
    @recent_events = Event.reorder(id: :desc).limit(5)

    # A mandate that runs out unnoticed is the failure this page exists to
    # prevent: the passport stays readable, so nothing looks wrong until
    # somebody tries to correct or end it. Nobody opens every passport to check
    # a date, so the ones that need a signature are named here.
    @mandates_due = Passport.where.not(delegation_expires_at: nil)
                            .where(delegation_expires_at: ..(Time.current + Did::Delegation::RENEW_WITHIN))
                            .where(retired_at: nil)
  end
end
