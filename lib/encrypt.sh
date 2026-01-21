#!/usr/bin/env bash
#
# lib/encrypt.sh - Encryption utilities (age and GPG support)
#
# Requires: core.sh to be sourced first
#

# ============================================================================
# Configuration
# ============================================================================

# Default paths for age keys
AGE_RECIPIENTS_FILE="${DBX_AGE_RECIPIENTS:-$CONFIG_DIR/age-recipients.txt}"
AGE_IDENTITY_FILE="${DBX_AGE_IDENTITY:-$HOME/.config/sops/age/keys.txt}"

# ============================================================================
# Encryption Type Detection
# ============================================================================

# Get configured encryption type (none, gpg, age)
get_encryption_type() {
  local enc_type
  enc_type=$(get_config_value ".defaults.encryption_type" 2>/dev/null || echo "")

  # Legacy support: if encryption=true but no type, assume gpg
  if [[ -z "$enc_type" ]]; then
    local enc_enabled
    enc_enabled=$(get_config_value ".defaults.encryption" 2>/dev/null || echo "")
    if [[ "$enc_enabled" == "true" ]]; then
      echo "gpg"
      return
    fi
  fi

  echo "${enc_type:-none}"
}

# Check if any encryption is enabled
is_any_encryption_enabled() {
  local enc_type
  enc_type=$(get_encryption_type)
  [[ "$enc_type" != "none" && -n "$enc_type" ]]
}

# ============================================================================
# Age Encryption
# ============================================================================

require_age() {
  command -v age &>/dev/null || die "age is required for encryption but not installed. Install with: nix-shell -p age"
}

# Get age recipients file path
get_age_recipients_file() {
  local custom_file
  custom_file=$(get_config_value ".defaults.age_recipients" 2>/dev/null || echo "")
  echo "${custom_file:-$AGE_RECIPIENTS_FILE}"
}

# Get age identity file path
get_age_identity_file() {
  local custom_file
  custom_file=$(get_config_value ".defaults.age_identity" 2>/dev/null || echo "")
  echo "${custom_file:-$AGE_IDENTITY_FILE}"
}

# Initialize age encryption (create recipients file if needed)
init_age_encryption() {
  local recipients_file
  recipients_file=$(get_age_recipients_file)

  if [[ -f "$recipients_file" ]]; then
    log_info "Age recipients file already exists: $recipients_file"
    return 0
  fi

  # Check for existing age identity
  local identity_file
  identity_file=$(get_age_identity_file)

  if [[ -f "$identity_file" ]]; then
    # Extract public key from identity file
    local public_key
    public_key=$(grep -v "^#" "$identity_file" | head -1 | age-keygen -y 2>/dev/null || true)

    if [[ -n "$public_key" ]]; then
      mkdir -p "$(dirname "$recipients_file")"
      echo "$public_key" > "$recipients_file"
      chmod 600 "$recipients_file"
      log_success "Created recipients file from existing identity: $recipients_file"
      return 0
    fi
  fi

  # Generate new age key pair
  log_info "Generating new age key pair..."
  mkdir -p "$(dirname "$identity_file")"
  age-keygen -o "$identity_file" 2>/dev/null

  # Extract public key
  local public_key
  public_key=$(age-keygen -y "$identity_file" 2>/dev/null)

  mkdir -p "$(dirname "$recipients_file")"
  echo "$public_key" > "$recipients_file"
  chmod 600 "$recipients_file"
  chmod 600 "$identity_file"

  log_success "Generated new age key pair"
  log_info "Identity (private): $identity_file"
  log_info "Recipients (public): $recipients_file"
  log_warn "Back up your identity file securely!"
}

# Encrypt stdin to stdout using age
age_encrypt_stream() {
  require_age

  local recipients_file
  recipients_file=$(get_age_recipients_file)

  if [[ ! -f "$recipients_file" ]]; then
    die "Age recipients file not found: $recipients_file. Run: dbx config init-encryption"
  fi

  age -R "$recipients_file" -
}

# Decrypt stdin to stdout using age
age_decrypt_stream() {
  require_age

  local identity_file
  identity_file=$(get_age_identity_file)

  if [[ ! -f "$identity_file" ]]; then
    die "Age identity file not found: $identity_file"
  fi

  age -d -i "$identity_file" -
}

# ============================================================================
# Unified Encryption Interface
# ============================================================================

# Encrypt stdin to stdout using configured method
encrypt_backup_stream() {
  local enc_type
  enc_type=$(get_encryption_type)

  case "$enc_type" in
    age)
      age_encrypt_stream
      ;;
    gpg)
      encrypt_stream
      ;;
    none|"")
      cat
      ;;
    *)
      die "Unknown encryption type: $enc_type"
      ;;
  esac
}

# Decrypt stdin to stdout (auto-detect format)
decrypt_backup_stream() {
  local file="$1"

  case "$file" in
    *.age)
      age_decrypt_stream
      ;;
    *.gpg)
      decrypt_stream
      ;;
    *)
      cat
      ;;
  esac
}

# Get file extension for encrypted backups
get_encryption_extension() {
  local enc_type
  enc_type=$(get_encryption_type)

  case "$enc_type" in
    age)
      echo ".age"
      ;;
    gpg)
      echo ".gpg"
      ;;
    *)
      echo ""
      ;;
  esac
}

# Check if a file is encrypted
is_file_encrypted() {
  local file="$1"
  [[ "$file" == *.age || "$file" == *.gpg ]]
}

# ============================================================================
# Decompress + Decrypt Combined
# ============================================================================

# Full decompression pipeline for backup files
# Handles: .sql.zst.age, .sql.zst.gpg, .sql.zst, .sql.age, .sql.gpg, .sql
decompress_backup() {
  local file="$1"

  case "$file" in
    *.sql.zst.age)
      require_age
      age_decrypt_stream < "$file" | zstd -d
      ;;
    *.sql.zst.gpg)
      require_gpg
      decrypt_stream < "$file" | zstd -d
      ;;
    *.sql.gz.age)
      require_age
      age_decrypt_stream < "$file" | gunzip
      ;;
    *.sql.gz.gpg)
      require_gpg
      decrypt_stream < "$file" | gunzip
      ;;
    *.sql.age)
      require_age
      age_decrypt_stream < "$file"
      ;;
    *.sql.gpg)
      require_gpg
      decrypt_stream < "$file"
      ;;
    *.zst)
      zstd -d < "$file"
      ;;
    *.gz)
      gunzip -c "$file"
      ;;
    *.sql)
      cat "$file"
      ;;
    *)
      # Try to detect by magic bytes
      if head -c 4 "$file" 2>/dev/null | grep -q $'\x28\xb5\x2f\xfd'; then
        zstd -d < "$file"
      elif head -c 2 "$file" 2>/dev/null | grep -q $'\x1f\x8b'; then
        gunzip -c "$file"
      else
        cat "$file"
      fi
      ;;
  esac
}
