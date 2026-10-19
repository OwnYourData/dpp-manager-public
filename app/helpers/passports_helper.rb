module PassportsHelper
  # The hint under "Placed on the market on". Before submission it says what
  # the date is for; afterwards, what it did: the period the service keeps the
  # passport for was worked out from it or, left empty, from the day of
  # submission. Where the product type sets no period, nothing was worked out,
  # and the hint does not say otherwise.
  def placed_on_market_note(passport)
    return t("passports.envelope.placed_on_market_hint") unless passport.submitted?
    return t("passports.envelope.placed_on_market_no_period") if passport.retain_until.blank?
    return t("passports.envelope.placed_on_market_fixed") if passport.placed_on_market_on.present?

    t("passports.envelope.placed_on_market_from_submission", date: l(passport.submitted_at.utc.to_date))
  end
end
