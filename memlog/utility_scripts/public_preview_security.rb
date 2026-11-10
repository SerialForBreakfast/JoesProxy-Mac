#!/usr/bin/env ruby
require "digest"
require "json"
require "yaml"

module PublicPreviewSecurity
  ROOT = File.expand_path("../..", __dir__)
  ACTIONS = {
    "actions/checkout" => "d23441a48e516b6c34aea4fa41551a30e30af803",
    "actions/upload-artifact" => "ea165f8d65b6e75b540449e92b4886f43607fa02",
    "github/codeql-action/init" => "33d7b85da1a04171e211befe2c739303b9a4c066",
    "github/codeql-action/analyze" => "33d7b85da1a04171e211befe2c739303b9a4c066"
  }.freeze

  def self.validate_workflow(document)
    raise "Workflow permissions must default to contents read" unless document["permissions"] == { "contents" => "read" }
    events = document.fetch("on")
    raise "Untrusted workflow trigger" unless (events.keys - %w[workflow_dispatch push schedule]).empty?
    raise "Pushes must target main" unless events.fetch("push").fetch("branches") == ["main"]
    groups = {
      "Public preview build" => "public-preview-build-${{ github.ref }}",
      "Public preview Swift security" => "public-preview-codeql-${{ github.ref }}",
      "Public preview secret scan" => "public-preview-secrets-${{ github.ref }}"
    }
    expected_group = groups.fetch(document.fetch("name"))
    raise "Workflows must queue independently by branch" unless document.fetch("concurrency") ==
      { "group" => expected_group, "cancel-in-progress" => false }
    document.fetch("jobs").each do |name, job|
      # CodeQL cannot trace builds on macOS 27 or Xcode 27; only that job uses the macOS 26 image.
      expected_runner = { "secrets" => "ubuntu-24.04", "codeql" => "macos-26" }.fetch(name, "xcode-27")
      raise "Unexpected runner" unless job.fetch("runs-on") == expected_runner
      raise "Missing bounded timeout" unless (1..60).cover?(job.fetch("timeout-minutes"))
      permissions = job.fetch("permissions", { "contents" => "read" })
      allowed = name == "codeql" ? { "contents" => "read", "security-events" => "write" } : { "contents" => "read" }
      raise "Excess job permissions" unless permissions == allowed
      job.fetch("steps").each do |step|
        next unless step["uses"]
        action, sha = step.fetch("uses").split("@", 2)
        raise "Unreviewed action revision" unless ACTIONS[action] == sha
        if action == "actions/checkout"
          raise "Checkout must not persist credentials" unless step.fetch("with")["persist-credentials"] == false
        end
        next unless action == "actions/upload-artifact"
        raise "Artifact retention exceeds three days" unless (1..3).cover?(step.fetch("with").fetch("retention-days"))
      end
    end
    true
  end

  def self.validate_findings(findings, reviewed, root: ROOT)
    raise "Scanner report must be an array" unless findings.is_a?(Array)
    records = reviewed.fetch("findings")
    findings.each do |finding|
      relative = finding.fetch("File").delete_prefix("./")
      expected = records.find do |entry|
        entry["file"] == relative && entry["rule"] == finding["RuleID"] && entry["line"] == finding["StartLine"]
      end
      raise "Unreviewed scanner finding at #{relative}" unless expected
      path = File.expand_path(relative, root)
      raise "Finding outside source" unless path.start_with?(root + "/") && File.realpath(path).start_with?(root + "/")
      raise "Reviewed source changed at #{relative}" unless Digest::SHA256.file(path).hexdigest == expected.fetch("sha256")
      raise "Unredacted finding" unless %w[Secret Match].all? { |field| finding.fetch(field).include?("REDACTED") }
    end
    { "observed" => findings.length, "reviewed" => findings.length, "unexpected" => 0 }
  end
end

if $PROGRAM_NAME == __FILE__
  case ARGV.shift
  when "workflows"
    paths = Dir.glob(File.join(PublicPreviewSecurity::ROOT, ".github/workflows/*.{yml,yaml}"))
    raise "No workflows found" if paths.empty?
    paths.each { |path| PublicPreviewSecurity.validate_workflow(YAML.safe_load(File.read(path), aliases: false)) }
    puts JSON.pretty_generate("validatedWorkflows" => paths.length)
  when "findings"
    report_path, summary_path = ARGV
    raise "Usage: findings REPORT SUMMARY" unless report_path && summary_path && ARGV.length == 2
    report = JSON.parse(File.read(report_path))
    reviewed = JSON.parse(File.read(File.join(PublicPreviewSecurity::ROOT, "Fixtures/Security/ReviewedSecretFindings.json")))
    result = PublicPreviewSecurity.validate_findings(report, reviewed)
    File.write(summary_path, JSON.pretty_generate(result) + "\n")
    puts JSON.pretty_generate(result)
  else
    abort "Usage: public_preview_security.rb workflows|findings REPORT SUMMARY"
  end
end
