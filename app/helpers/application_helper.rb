module ApplicationHelper
  # Is the page being shown inside this part of the application?
  #
  # The bar used to say where you are with an underline under one of eight
  # links. With the pages grouped into menus that mark has to move up to the
  # group, or the bar stops answering "where am I" the moment a page is one
  # level down — which is most of them: a passport being edited is under
  # /passports, and `current_page?` would say no.
  #
  # Prefixes, therefore, and never the root path: "/" is the prefix of
  # everything.
  def nav_section?(*prefixes)
    prefixes.compact.any? { |prefix| request.path == prefix || request.path.start_with?("#{prefix}/") }
  end

  # The DPP Service this installation submits to, for the link in the bar: the
  # one set up, and until there is one the one setup suggests. While the vault
  # is closed nothing set up can be read, so it is the suggestion then too.
  def dpp_service_url
    (settings.service_base_url.presence if vault_open?) || Setting::DEFAULT_SERVICE_BASE_URL
  end

  # The funding notice for the footer, in the wording of config/funding.yml.
  # It stays in English in every language of the application: it is quoted as
  # agreed with the project, not translated.
  def funding_notice
    FundingNotice.html.html_safe
  end
end
