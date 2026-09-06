# Reading a passport that is not this installation's.
#
# The one screen in the application that does not write anything and needs no
# identity. That is the standard's own asymmetry: writing a passport is an
# operator's signed act, reading one is what a passport is for. Anybody holding
# the product holds its identifier, and holding the identifier is the whole
# permission.
#
# Two kinds of identifier are accepted, and each takes its own route to the same
# document:
#
#   a DID          resolved at the registry; the address to read it at comes out
#                  of the document its holder published. Nothing here decides
#                  where a foreign passport lives.
#   a product id   looked up at the service this installation is configured with.
#                  It is the only service this application knows of, and saying
#                  that is more honest than pretending to search.
class LookupsController < ApplicationController
  # What comes back is shown as it is, and — when a product type here can read
  # it — also as answers in the shape of that type's form. Both, not one: the
  # element tree is what the passport actually says, and the form view is this
  # installation's reading of it. Showing only the second would quietly hide
  # everything this type has no field for.
  def show
    @identifier = params[:identifier].to_s.strip
    return if @identifier.blank?

    document = fetch(@identifier)
    return if document.nil?

    @document = document
    @type     = readable_type
    @answers  = answers_for(@document, @type)

    Event.record!(:passport_read, identifier: @identifier,
                                  dpp_id: @document["digitalProductPassportId"])
  end

  # A local draft from what was read.
  #
  # The document is fetched again rather than carried through the browser in a
  # hidden field: it travelled once already, and a copy that came back through a
  # form is a copy somebody could have edited.
  #
  # The product identifier is deliberately NOT copied. It names somebody else's
  # product, and a draft that carried it would mint a DID pointing at a product
  # this operator does not make. What is copied is the answers — which is what
  # this screen is for: a component's passport as the starting point for one's
  # own.
  def draft
    identifier = params[:identifier].to_s.strip
    type = ProductType.fetched.find_by(id: params[:product_type_id])
    return redirect_to(lookup_path(identifier: identifier), alert: t("lookup.draft.no_type")) if type.nil?

    document = fetch(identifier)
    return redirect_to(lookup_path(identifier: identifier), alert: flash[:alert]) if document.nil?

    answers = answers_for(document, type)
    if answers.blank?
      return redirect_to lookup_path(identifier: identifier), alert: t("lookup.draft.nothing_readable")
    end

    passport = Passport.new(product_type: type, label: suggested_label(answers, document))
    passport.values = answers
    passport.save!

    redirect_to edit_passport_path(passport), notice: t("lookup.draft.created")
  end

  private

  # nil and a flash on every failure, so the caller has one thing to check. The
  # sentence is the registry's or the service's own wherever there is one.
  def fetch(identifier)
    result = identifier.start_with?("did:") ? read_by_did(identifier) : read_by_product_id(identifier)
    return nil if result.nil?

    unless result.ok?
      flash.now[:alert] = refusal(result)
      Event.record!(:passport_read_failed, identifier: identifier, status: result.http_status)
      return nil
    end

    document = result.document
    return document if document.is_a?(Hash) && document.key?("elements")

    flash.now[:alert] = t("lookup.not_a_passport")
    nil
  rescue DppService::Client::Error => e
    flash.now[:alert] = t("lookup.unreachable", message: t("passports.submit.reasons.#{e.message}", default: e.message))
    Event.record!(:passport_read_failed, identifier: identifier, message: e.message)
    nil
  end

  def read_by_did(did)
    DppService::Client.read(Did::Oyd.passport_endpoint(did))
  rescue Did::Oyd::Error => e
    flash.now[:alert] = t("lookup.did_failed", message: e.message)
    Event.record!(:passport_read_failed, identifier: did, message: e.message)
    nil
  end

  def read_by_product_id(product_id)
    base = settings.service_base_url
    if base.blank?
      flash.now[:alert] = t("lookup.no_service")
      return nil
    end

    DppService::Client.read_by_product_id(base_url: base, product_id: product_id)
  end

  # 404 is the answer to expect and deserves its own sentence: a passport that
  # was never there and one that was ended both come back this way, and "the
  # service refused it (HTTP 404)" says neither.
  def refusal(result)
    return t("lookup.not_found") if result.http_status == 404

    t("passports.submit.refused", status: result.http_status, problems: result.problems.join(" · "))
  end

  # Which type reads this document. The operator's choice when they made one,
  # and otherwise the only candidate — with more than one, nothing, because
  # guessing which of several structures a foreign passport was written against
  # is a guess whose being wrong is invisible.
  def readable_type
    candidates = ProductType.fetched.select(&:readable?)
    chosen = candidates.find { |type| type.id.to_s == params[:product_type_id].to_s }

    chosen || (candidates.first if candidates.one?)
  end

  def answers_for(document, type)
    return nil if type.nil?

    Dpp::Document.answers_from(document, type)
  rescue Dpp::Document::Error => e
    flash.now[:alert] = t("lookup.read_failed", reason: t("passports.submit.reasons.#{e.message}", default: e.message))
    nil
  end

  # Something to recognise the draft by in the list. The product's own words
  # where it gave any, and the identifier when it did not.
  def suggested_label(answers, document)
    name = answers.values_at("productDesignation", "modelIdentifier").compact_blank.first
    [ name.presence || document["uniqueProductIdentifier"].to_s.split("/").last,
      t("lookup.draft.suffix") ].compact_blank.join(" ").first(200)
  end
end
