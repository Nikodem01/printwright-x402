require "test_helper"

# The README points a judge at two committed copies of the same proof bundle:
# widget-example.html for the browser widget, widget-example.bundle.json for
# `node verifier/cli.js`, which takes JSON and exits 1 on HTML. Two copies can
# drift, and the README instruction is only true while they agree — so pin the
# agreement rather than the files.
class PublicProofBundleTest < ActiveSupport::TestCase
  HTML = Rails.root.join("public/widget-example.html")
  JSON_BUNDLE = Rails.root.join("public/widget-example.bundle.json")

  def embedded_bundle
    match = HTML.read[%r{<script type="application/json">(.*?)</script>}m]
    assert_not_nil match, "widget-example.html no longer embeds a proof bundle"
    JSON.parse(Regexp.last_match(1))
  end

  test "the standalone bundle the README hands the CLI is valid JSON" do
    assert_path_exists JSON_BUNDLE,
      "README tells a judge to run the verifier against this file"
    bundle = JSON.parse(JSON_BUNDLE.read)

    assert_equal 1, bundle["proof_version"]
    assert_equal "sha256-jcs-v1", bundle["algorithm"]
    %w[certificate blinding_nonce commitment terms hedera].each do |key|
      assert bundle[key].present?, "proof bundle is missing #{key}"
    end
  end

  test "the standalone bundle is byte-for-byte the same proof as the widget's" do
    assert_equal embedded_bundle, JSON.parse(JSON_BUNDLE.read),
      "public/widget-example.bundle.json has drifted from the bundle embedded " \
      "in widget-example.html; the README presents them as the same purchase"
  end

  test "the README names the JSON bundle for the CLI, not the HTML page" do
    readme = Rails.root.join("README.md").read

    assert_includes readme, "node verifier/cli.js public/widget-example.bundle.json"
    assert_no_match(/verifier\/cli\.js\s+public\/widget-example\.html/, readme,
      "the verifier exits 1 with invalid_input when handed the HTML page")
  end
end
