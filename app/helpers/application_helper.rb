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
end
