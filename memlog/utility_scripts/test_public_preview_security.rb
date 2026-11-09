require "fileutils"
require "minitest/autorun"
require "tmpdir"
require_relative "public_preview_security"

class PublicPreviewSecurityTests < Minitest::Test
  def workflow
    path = File.join(PublicPreviewSecurity::ROOT, ".github/workflows/public-preview-build.yml")
    YAML.safe_load(File.read(path), aliases: false)
  end

  def test_all_shipped_workflows_pass
    paths = Dir.glob(File.join(PublicPreviewSecurity::ROOT, ".github/workflows/*.yml"))
    assert_equal 3, paths.length
    paths.each { |path| assert PublicPreviewSecurity.validate_workflow(YAML.safe_load(File.read(path), aliases: false)) }
  end

  def test_rejects_untrusted_pull_request_triggers
    document = workflow
    document["on"]["pull_request_target"] = {}
    assert_raises(RuntimeError) { PublicPreviewSecurity.validate_workflow(document) }
  end

  def test_build_and_security_queues_cannot_replace_each_other
    document = workflow
    document["concurrency"]["group"] = "public-preview-codeql-${{ github.ref }}"
    assert_raises(RuntimeError) { PublicPreviewSecurity.validate_workflow(document) }
  end

  def test_rejects_runner_without_the_required_toolchain
    document = workflow
    document["jobs"]["build"]["runs-on"] = "macos-26"
    assert_raises(RuntimeError) { PublicPreviewSecurity.validate_workflow(document) }
    document["jobs"]["build"]["runs-on"] = "ubuntu-24.04"
    assert_raises(RuntimeError) { PublicPreviewSecurity.validate_workflow(document) }
  end

  def test_rejects_branch_and_permission_expansion
    document = workflow
    document["on"]["push"]["branches"] << "**"
    assert_raises(RuntimeError) { PublicPreviewSecurity.validate_workflow(document) }
    document = workflow
    document["permissions"]["contents"] = "write"
    assert_raises(RuntimeError) { PublicPreviewSecurity.validate_workflow(document) }
    document = workflow
    document["jobs"]["build"]["permissions"] = { "contents" => "read", "security-events" => "write" }
    assert_raises(RuntimeError) { PublicPreviewSecurity.validate_workflow(document) }
  end

  def test_rejects_unpinned_or_unreviewed_action_revisions
    document = workflow
    document["jobs"]["build"]["steps"][0]["uses"] = "actions/checkout@v6"
    assert_raises(RuntimeError) { PublicPreviewSecurity.validate_workflow(document) }
    document["jobs"]["build"]["steps"][0]["uses"] = "actions/checkout@" + "0" * 40
    assert_raises(RuntimeError) { PublicPreviewSecurity.validate_workflow(document) }
  end

  def test_rejects_persistent_credentials_and_long_artifact_retention
    document = workflow
    document["jobs"]["build"]["steps"][0]["with"]["persist-credentials"] = true
    assert_raises(RuntimeError) { PublicPreviewSecurity.validate_workflow(document) }
    document = workflow
    document["jobs"]["build"]["steps"][-1]["with"]["retention-days"] = 90
    assert_raises(RuntimeError) { PublicPreviewSecurity.validate_workflow(document) }
  end

  def with_fixture
    base = File.join(PublicPreviewSecurity::ROOT, "build/PreviewValidatorTests")
    FileUtils.mkdir_p(base)
    Dir.mktmpdir("review-", base) do |root|
      path = File.join(root, "fixture.txt")
      File.write(path, "synthetic fixture\n")
      finding = { "File" => "fixture.txt", "RuleID" => "fixture", "StartLine" => 1,
                  "Secret" => "REDACTED", "Match" => "REDACTED" }
      reviewed = { "findings" => [{ "file" => "fixture.txt", "rule" => "fixture", "line" => 1,
                                   "sha256" => Digest::SHA256.file(path).hexdigest }] }
      yield root, path, finding, reviewed
    end
  end

  def test_known_exact_file_is_accepted_without_hiding_other_findings
    with_fixture do |root, _, finding, reviewed|
      summary = PublicPreviewSecurity.validate_findings([finding], reviewed, root: root)
      assert_equal 1, summary["reviewed"]
      other = finding.merge("RuleID" => "unexpected")
      assert_raises(RuntimeError) { PublicPreviewSecurity.validate_findings([finding, other], reviewed, root: root) }
    end
  end

  def test_changed_contents_at_same_location_require_review
    with_fixture do |root, path, finding, reviewed|
      File.write(path, "changed synthetic fixture\n")
      assert_raises(RuntimeError) { PublicPreviewSecurity.validate_findings([finding], reviewed, root: root) }
    end
  end

  def test_unredacted_reports_fail_closed
    with_fixture do |root, _, finding, reviewed|
      finding["Secret"] = "synthetic-raw-value"
      assert_raises(RuntimeError) { PublicPreviewSecurity.validate_findings([finding], reviewed, root: root) }
    end
  end

  def test_unknown_location_and_traversal_fail_closed
    with_fixture do |root, _, finding, reviewed|
      finding["StartLine"] = 2
      assert_raises(RuntimeError) { PublicPreviewSecurity.validate_findings([finding], reviewed, root: root) }
      finding["StartLine"] = 1
      finding["File"] = "../outside.txt"
      reviewed["findings"][0]["file"] = "../outside.txt"
      assert_raises(RuntimeError) { PublicPreviewSecurity.validate_findings([finding], reviewed, root: root) }
    end
  end

  def test_clean_scan_is_accepted
    assert_equal 0, PublicPreviewSecurity.validate_findings([], { "findings" => [] })["observed"]
  end
end
