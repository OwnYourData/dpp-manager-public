# Who may read which field of the passports of a product type.
#
# One row per element path the type's transformation produces, with the form
# fields that end up there and the class the operator chooses for it: public,
# readers with a legitimate interest, or authorities. The structure's author
# may suggest classes in an OverlayClassification; those are the starting
# point, and the operator's choice replaces them.
#
# Switched on, the classes become the access policy of the type. It is
# registered with the DPP Service right away when one is set up, so a refusal
# is seen here rather than at the first passport, and again before every write
# that names it.
class ProductTypeAccessController < ApplicationController
  before_action :find_product_type

  def edit
    load_rows
  end

  def update
    enabled = params[:enabled] == "1"

    if !enabled && @product_type.access_policy_enabled? && @product_type.classified_passports.exists?
      return redirect_to(product_type_access_path(@product_type), alert: t("product_type_access.cannot_switch_off"))
    end

    rows = @product_type.access_rows
    classes = params.fetch(:classes, {}).permit(*rows.map { |row| row["path"] }).to_h
    bumped = @product_type.store_access_classes!(classes, enabled: enabled, rows: rows)

    Event.record!(:product_type_access_changed, label: @product_type.label, enabled: enabled,
                                                version: @product_type.access_policy_version)

    notice = t(enabled ? (bumped ? "product_type_access.saved_version" : "product_type_access.saved_on")
                       : "product_type_access.saved_off", version: @product_type.access_policy_version)
    register_and_redirect(notice)
  rescue Dpp::AccessPaths::Error => e
    redirect_to product_type_access_path(@product_type), alert: t("product_type_access.reasons.#{e.message}")
  end

  private

  def find_product_type
    @product_type = ProductType.find(params[:id])
  end

  def load_rows
    @rows = @product_type.access_rows
    @classes = @product_type.effective_access_classes(@rows)
    @suggestions = @product_type.access_class_suggestions
    @labels = @product_type.field_labels
  rescue Dpp::AccessPaths::Error => e
    @rows = nil
    @error = t("product_type_access.reasons.#{e.message}")
  end

  # Without a service or an identity there is nothing to register with yet;
  # the first passport does it.
  def register_and_redirect(notice)
    unless @product_type.access_policy_enabled? && settings.service_configured? && Identity.current
      return redirect_to(product_type_access_path(@product_type), notice: notice)
    end

    DppService::AccessPolicyRegistration.ensure!(@product_type, base_url: settings.service_base_url,
                                                                audience: settings.service_audience)
    redirect_to product_type_access_path(@product_type),
                notice: "#{notice} #{t('product_type_access.registered', service: settings.service_base_url)}"
  rescue DppService::AccessPolicyRegistration::Error => e
    reason = e.problems.any? ? e.problems.join(" · ") : t("passports.access_policy.reasons.#{e.message}")
    redirect_to product_type_access_path(@product_type),
                notice: notice, alert: t("product_type_access.not_registered", reason: reason)
  rescue DppService::Client::Error, Did::Oyd::Error => e
    redirect_to product_type_access_path(@product_type),
                notice: notice, alert: t("product_type_access.not_registered", reason: e.message)
  end
end
