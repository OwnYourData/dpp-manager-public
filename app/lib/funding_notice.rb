# frozen_string_literal: true

require "erb"
require "yaml"

# The funding notice of PACE-DPP, kept once in config/funding.yml.
#
# The footer renders it from there on every page. The README cannot read the
# configuration, so it holds a copy between two markers, and
# `bin/rails funding:write` replaces that copy with what the configuration
# says. A test compares them, so a copy that was not rewritten does not go
# unnoticed.
module FundingNotice
  ROOT = File.expand_path("../..", __dir__)
  SOURCE = File.join(ROOT, "config", "funding.yml")
  README = File.join(ROOT, "README.md")
  BEGIN_MARK = "<!-- funding:begin -->"
  END_MARK = "<!-- funding:end -->"
  LINK = /\[([^\]]+)\]\(([^)\s]+)\)/

  module_function

  def settings
    YAML.safe_load_file(SOURCE)
  end

  # For the README: Markdown, with the full title of the project.
  def markdown
    s = settings
    format(s.fetch("text"), component: s.fetch("component"), title: " – #{s.fetch("title")}")
  end

  # For the footer: HTML without the title. The links leave the application,
  # so they open in a new tab, like the other link out of the footer.
  def html
    s = settings
    text = format(s.fetch("text"), component: s.fetch("component"), title: "")
    String.new(ERB::Util.html_escape(text)).gsub(LINK) do
      %(<a class="quiet" href="#{Regexp.last_match(2)}" target="_blank" rel="noopener">#{Regexp.last_match(1)}</a>)
    end
  end

  def current(path = README)
    content = File.read(path, encoding: "UTF-8")
    start = content.index(BEGIN_MARK) or return nil
    stop = content.index(END_MARK, start) or return nil
    content[(start + BEGIN_MARK.length)...stop].strip
  end

  def write!(path = README)
    content = File.read(path, encoding: "UTF-8")
    region = /#{Regexp.escape(BEGIN_MARK)}.*?#{Regexp.escape(END_MARK)}/m
    raise "#{path}: no funding markers" unless content.match?(region)

    File.write(path, content.sub(region) { "#{BEGIN_MARK}\n#{markdown}\n#{END_MARK}" })
  end
end
