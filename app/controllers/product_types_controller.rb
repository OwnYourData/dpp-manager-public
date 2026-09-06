# The list of passport kinds this installation knows, and where each one's
# description lives.
#
# A row is an address until it is fetched, and a working description afterwards.
# The two are kept apart deliberately: adding a row costs nothing and needs no
# network, and the operator finds out what a structure actually contains at the
# moment they ask for it, with the reason in front of them if it fails.
class ProductTypesController < ApplicationController
  before_action :find_product_type, only: %i[edit update destroy refresh]

  def index
    @product_types = ProductType.all
    @seed_pending = Soya::Seed.pending?
    @web_cli = Soya::WebCli.version
  rescue Soya::Error
    @web_cli = nil
  end

  # The product types the image ships with, for a vault that was created before
  # they existed — a new vault gets them on creation. Offered rather than done
  # automatically: a type somebody deleted is a decision, and an application
  # that puts it back on every start is arguing with them.
  def install_bundled
    result = Soya::Seed.install!

    if result.installed.any?
      redirect_to product_types_path,
        notice: t("product_types.bundled.installed", count: result.installed.size,
                                                     labels: result.installed.map(&:label).to_sentence)
    else
      redirect_to product_types_path, alert: t("product_types.bundled.nothing_installed")
    end
  end

  def new
    @product_type = ProductType.new(repo_base_url: Soya::Repository::DEFAULT_REPO)
  end

  def create
    @product_type = ProductType.new(permitted)

    if @product_type.save
      Event.record!(:product_type_added,
        label: @product_type.label, structure: @product_type.structure_name, repo: @product_type.repo_base_url)
      refresh_and_redirect(@product_type, t("product_types.added"))
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    # Pointing a row at a different structure invalidates what was fetched for
    # the old one. Keeping the cached copy under the new name would be worse
    # than having none: the form would render, and it would be the wrong form.
    incoming = ProductType.new(permitted)
    address_changed = incoming.repo_base_url != @product_type.repo_base_url ||
                      incoming.structure_name != @product_type.structure_name ||
                      incoming.form_tag.to_s != @product_type.form_tag.to_s

    if @product_type.update(permitted)
      Event.record!(:product_type_changed,
        label: @product_type.label, structure: @product_type.structure_name, repo: @product_type.repo_base_url)

      if address_changed
        @product_type.update!(jsonld: nil, yaml: nil, dri: nil, forms: nil, fetched_at: nil)
        return refresh_and_redirect(@product_type, t("product_types.saved"))
      end

      redirect_to product_types_path, notice: t("product_types.saved")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    label = @product_type.label
    @product_type.destroy
    Event.record!(:product_type_removed, label: label, structure: @product_type.structure_name)
    redirect_to product_types_path, notice: t("product_types.removed", label: label)
  end

  def refresh
    refresh_and_redirect(@product_type, nil)
  end

  private

  def find_product_type
    @product_type = ProductType.find(params[:id])
  end

  def refresh_and_redirect(product_type, prefix)
    result = Soya::Import.refresh(product_type)

    if result.ok?
      message = t("product_types.fetched", languages: result.languages.map(&:upcase).join(", "))
      redirect_to product_types_path, notice: [ prefix, message ].compact.join(" ")
    else
      # The row stays. What failed is the fetch, and the operator is the only
      # one who can tell whether the name is wrong or the repository is down —
      # so they get the message the repository or soya-web-cli actually gave.
      redirect_to product_types_path, alert: t("product_types.fetch_failed", message: result.error)
    end
  end

  def permitted
    params.require(:product_type).permit(:label, :repo_base_url, :structure_name, :form_tag, :transformation_name,
                                        :reverse_transformation_name)
  end
end
