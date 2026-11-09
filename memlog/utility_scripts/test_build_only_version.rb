require "minitest/autorun"
require "open3"

class BuildOnlyVersionTests < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  CONFIG = File.join(ROOT, "Config/Version.xcconfig")

  def setup
    @before = File.read(CONFIG)
    @version = @before.match(/^MARKETING_VERSION = (\S+)/)[1]
    @build = Integer(@before.match(/^CURRENT_PROJECT_VERSION = (\d+)/)[1])
  end

  def teardown
    assert_equal @before, File.read(CONFIG), "Dry-run or rejected input must never modify configuration"
  end

  def run_helper(*arguments)
    Open3.capture3("bash", File.join(ROOT, "bump_version.sh"), *arguments)
  end

  def test_build_only_dry_run_preserves_marketing_version
    output, _, status = run_helper(@version, "--build-only", "--build", (@build + 1).to_s, "--dry-run")
    assert status.success?
    assert_includes output, "retain version #{@version}"
    assert_includes output, "build #{@build} to #{@build + 1}"
  end

  def test_rejects_nonmonotonic_build
    _, _, status = run_helper(@version, "--build-only", "--build", @build.to_s, "--dry-run")
    refute status.success?
  end

  def test_rejects_marketing_version_change
    _, _, status = run_helper("999.0.0", "--build-only", "--dry-run")
    refute status.success?
  end

  def test_rejects_release_date_change
    _, _, status = run_helper(@version, "--build-only", "--date", "2026-11-08", "--dry-run")
    refute status.success?
  end

  def test_release_controller_previews_without_writing_outputs
    destination = File.join(ROOT, "build/ReleaseControllerDryRun")
    before = File.exist?(destination)
    output, _, status = Open3.capture3("zsh", File.join(ROOT, "memlog/utility_scripts/private_candidate_release.sh"),
                                      ".", "build/ReleaseControllerDryRun", "--dry-run")
    assert status.success?
    assert_includes output, "bundle exec fastlane mac release"
    assert_equal before, File.exist?(destination)
  end

  def test_release_controller_rejects_escape_and_nonbuild_outputs
    [["../outside", "build/ReleaseControllerDryRun"], [".", "../outside"], [".", "Config/BadOutput"]].each do |source, output|
      _, _, status = Open3.capture3("zsh", File.join(ROOT, "memlog/utility_scripts/private_candidate_release.sh"),
                                    source, output, "--dry-run")
      refute status.success?
    end
  end
end
