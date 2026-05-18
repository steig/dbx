#!/usr/bin/env bats
load '../helpers/common'
setup() { setup_dbx_env; source_dbx_libs; }

# Stub storage_upload/list/download/delete so we can test the
# orchestration logic of storage_test_roundtrip without a real S3.
stub_storage_ok() {
  storage_upload()   { echo "uploaded:$1:$2"; return 0; }
  storage_list()     { echo ".dbx-test/probe-$(date +%s)"; return 0; }
  storage_download() {
    local remote="$1" local_file="$2"
    cp "${UPLOAD_SRC:-/dev/null}" "$local_file" 2>/dev/null
    return 0
  }
  storage_delete()   { return 0; }
  export -f storage_upload storage_list storage_download storage_delete
}

@test "storage_test_roundtrip: all steps succeed -> exit 0" {
  stub_storage_ok
  # Ensure is_storage_configured returns true by writing a minimal storage block
  echo '{"storage": {"type": "s3", "s3": {"bucket": "x", "endpoint": "http://x"}}}' > "$CONFIG_FILE"

  # Configure UPLOAD_SRC so the download stub copies the same 1-byte content
  # We can't easily intercept the probe_src created inside the function, so
  # override storage_download to write a "." byte (matching probe_src content).
  storage_download() { printf '.' > "$2"; return 0; }
  export -f storage_download

  run storage_test_roundtrip
  [ "$status" -eq 0 ]
  [[ "$output" =~ "round-trip OK" ]]
}

@test "storage_test_roundtrip: upload failure -> non-zero" {
  echo '{"storage": {"type": "s3", "s3": {"bucket": "x"}}}' > "$CONFIG_FILE"
  storage_upload()   { return 1; }
  storage_list()     { return 0; }
  storage_download() { return 0; }
  storage_delete()   { return 0; }
  export -f storage_upload storage_list storage_download storage_delete

  run storage_test_roundtrip
  [ "$status" -ne 0 ]
  [[ "$output" =~ "upload failed" ]]
}

@test "storage_test_roundtrip: list doesn't contain probe -> non-zero" {
  echo '{"storage": {"type": "s3", "s3": {"bucket": "x"}}}' > "$CONFIG_FILE"
  storage_upload()   { return 0; }
  storage_list()     { echo "other-file"; return 0; }
  storage_download() { return 0; }
  storage_delete()   { return 0; }
  export -f storage_upload storage_list storage_download storage_delete

  run storage_test_roundtrip
  [ "$status" -ne 0 ]
  [[ "$output" =~ "list" ]]
}

@test "storage_test_roundtrip: download byte-mismatch -> non-zero" {
  echo '{"storage": {"type": "s3", "s3": {"bucket": "x"}}}' > "$CONFIG_FILE"
  storage_upload()   { return 0; }
  storage_list()     { echo ".dbx-test/probe-$(date +%s)"; return 0; }
  storage_download() { echo "different" > "$2"; return 0; }   # multi-byte ≠ "."
  storage_delete()   { return 0; }
  export -f storage_upload storage_list storage_download storage_delete

  run storage_test_roundtrip
  [ "$status" -ne 0 ]
  [[ "$output" =~ "mismatch" ]]
}

@test "storage_test_roundtrip: delete failure -> non-zero" {
  echo '{"storage": {"type": "s3", "s3": {"bucket": "x"}}}' > "$CONFIG_FILE"
  storage_upload()   { return 0; }
  storage_list()     { echo ".dbx-test/probe-$(date +%s)"; return 0; }
  storage_download() { printf '.' > "$2"; return 0; }
  storage_delete()   { return 1; }
  export -f storage_upload storage_list storage_download storage_delete

  run storage_test_roundtrip
  [ "$status" -ne 0 ]
  [[ "$output" =~ "delete failed" ]]
}
