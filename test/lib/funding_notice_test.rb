require "test_helper"

# The wording lives in config/funding.yml. The footer reads it from there; the
# README carries a copy, and this test fails when that copy has not been
# rewritten with `bin/rails funding:write`.
class FundingNoticeTest < ActiveSupport::TestCase
  test "names this component, the project and the grant" do
    text = FundingNotice.markdown

    assert text.start_with?("The DPP Manager is part of [PACE-DPP](https://dpp-austria.at/) – Promoting")
    assert_includes text, "under grant number [917177](https://projekte.ffg.at/projekt/5128301)"
    assert text.end_with?("supported by the German Research Promotion Agency (DLR-PT).")
  end

  test "turns the links into quiet links for the footer and leaves out the title" do
    html = FundingNotice.html

    assert html.start_with?('The DPP Manager is part of <a class="quiet" href="https://dpp-austria.at/" target="_blank" rel="noopener">PACE-DPP</a>. This Lighthouse Project')
    assert_includes html, '<a class="quiet" href="https://projekte.ffg.at/projekt/5128301" target="_blank" rel="noopener">917177</a>'
    assert_not_includes html, "Promoting and Accelerating"
    assert_not_includes html, "]("
  end

  test "the README carries the notice as the configuration says, before the licence" do
    readme = File.read(FundingNotice::README, encoding: "UTF-8")

    assert_equal FundingNotice.markdown, FundingNotice.current
    assert readme.index("## Funding") < readme.index("## Licence")
  end
end
