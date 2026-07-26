#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 1 || $# -gt 3 ]]; then
  echo "Usage: $0 <result-bundle.xcresult> [threshold-percent] [target-name]" >&2
  exit 2
fi

result_bundle=$1
threshold=${2:-70}
target_name=${3:-OOChatIOS.app}

if [[ ! -d "$result_bundle" ]]; then
  echo "Coverage result bundle does not exist: $result_bundle" >&2
  exit 2
fi

coverage_json=$(mktemp)
trap 'rm -f "$coverage_json"' EXIT

xcrun xccov view --report --json "$result_bundle" > "$coverage_json"

ruby -rjson - "$coverage_json" "$target_name" "$threshold" <<'RUBY'
coverage_path, target_name, threshold_text = ARGV

begin
  report = JSON.parse(File.read(coverage_path))
  threshold = Float(threshold_text)
rescue JSON::ParserError, ArgumentError => error
  warn "Unable to read coverage data: #{error.message}"
  exit 2
end

target = report.fetch("targets", []).find { |candidate| candidate["name"] == target_name }
unless target
  available_targets = report.fetch("targets", []).map { |candidate| candidate["name"] }
  warn "Coverage target '#{target_name}' was not found."
  warn "Available targets: #{available_targets.join(', ')}"
  exit 2
end

coverage = Float(target.fetch("lineCoverage")) * 100
covered_lines = target["coveredLines"]
executable_lines = target["executableLines"]
line_detail = if covered_lines && executable_lines
                " (#{covered_lines}/#{executable_lines} executable lines)"
              else
                ""
              end

message = format(
  "Line coverage for %<target>s: %<coverage>.2f%%%<detail>s; required: > %<threshold>.2f%%",
  target: target_name,
  coverage: coverage,
  detail: line_detail,
  threshold: threshold
)
puts message

if ENV["GITHUB_STEP_SUMMARY"]
  File.open(ENV.fetch("GITHUB_STEP_SUMMARY"), "a") do |summary|
    summary.puts "## Test coverage"
    summary.puts
    summary.puts "| Target | Line coverage | Required |"
    summary.puts "| --- | ---: | ---: |"
    summary.puts format("| `%s` | %.2f%% | > %.2f%% |", target_name, coverage, threshold)
  end
end

if coverage <= threshold
  warn format(
    "Coverage gate failed: %.2f%% is not greater than %.2f%%.",
    coverage,
    threshold
  )
  exit 1
end
RUBY

