#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# `--show-bin-path` works with both SwiftPM build layouts.
bin="$(swift build --package-path WorkflowCore -c release --show-bin-path)/workflow-validator"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
check() {
  expected="$1"; shift
  set +e
  "$bin" "$@" > "$tmp/output.json"
  actual=$?
  set -e
  test "$actual" -eq "$expected" || { cat "$tmp/output.json"; echo "Expected $expected, got $actual"; exit 1; }
}
check 0 validate examples --format json
python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); assert r["valid"] and r["files_checked"] == 3 and not r["diagnostics"]' "$tmp/output.json"
mkdir "$tmp/empty"
check 0 validate "$tmp/empty" --format json
python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); assert r["valid"] and r["files_checked"] == 0' "$tmp/output.json"
check 2 validate "$tmp/missing" --format json
python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); assert not r["valid"] and r["diagnostics"][0]["code"] == "io"' "$tmp/output.json"
printf 'schema_version: 42\n' > "$tmp/empty/bad.workflow.yaml"
check 1 validate "$tmp/empty" --format json
python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); assert not r["valid"] and r["files_checked"] == 1; assert {"file","field","code","message"} <= r["diagnostics"][0].keys()' "$tmp/output.json"
check 2 validate
check 2 validate examples --format xml
printf 'Validator exit codes and JSON contract passed.\n'
