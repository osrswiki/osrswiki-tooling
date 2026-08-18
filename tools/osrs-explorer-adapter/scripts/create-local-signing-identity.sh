#!/bin/zsh -f
set -euo pipefail
umask 077

if [[ "${1:-}" == "--probe-startup-sanitization" && "$#" == 1 ]]; then
  print -r -- "SHELL_STARTUP_SANITIZED"
  exit 0
fi

security_tool="/usr/bin/security"
command_supervisor="${0:A:h}/run-bounded-command.pl"
case "$#" in
  0) ;;
  2)
    [[ "$1" == "--offline-security-shim" && -x "$2" ]] || {
      print -u2 "USAGE:$0 [--probe-startup-sanitization|--offline-security-shim EXECUTABLE]"
      exit 64
    }
    security_tool="${2:A}"
    ;;
  *)
    print -u2 "USAGE:$0 [--probe-startup-sanitization|--offline-security-shim EXECUTABLE]"
    exit 64
    ;;
esac
[[ -x "$command_supervisor" ]] || {
  print -u2 "BOUNDED_COMMAND_SUPERVISOR_REQUIRED:$command_supervisor"
  exit 1
}

identity="OSRS Explorer Adapter Local Signing"
keychain="$HOME/Library/Keychains/login.keychain-db"
policy_root="$HOME/Library/Application Support/OSRS Explorer Adapter"
policy="$policy_root/signing-policy.json"
temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/osrs-adapter-signing.XXXXXX")"
certificate_mutation_attempted=false
private_key_mutation_attempted=false
trust_mutation_attempted=false
identity_committed=false
policy_root_created=false
policy_publish_attempted=false
policy_inode=""
policy_staging_directory=""
policy_property_list=""
policy_temporary=""
certificate_sha256=""

certificate_pem_count() {
  /usr/bin/printf '%s\n' "$1" \
    | /usr/bin/awk '/-----BEGIN CERTIFICATE-----/ { count += 1 } END { print count + 0 }'
}

cleanup() {
  local failed=false
  local cleanup_status=0
  local observed_policy_inode=""
  local certificate_lookup_output=""
  local certificate_lookup_status=0
  local certificate_lookup_count=0
  local private_key_lookup_output=""
  local private_key_lookup_status=0
  local trust_verification_status=0
  if [[ "$identity_committed" != true ]]; then
    if [[ "$private_key_mutation_attempted" == true \
      || "$trust_mutation_attempted" == true ]]; then
      cleanup_status=0
      "$security_tool" delete-identity -Z "$certificate_sha256" -t "$keychain" \
        >/dev/null 2>&1 || cleanup_status=$?
      if [[ "$cleanup_status" == 44 && "$certificate_mutation_attempted" == true ]]; then
        cleanup_status=0
        "$security_tool" delete-certificate -Z "$certificate_sha256" -t "$keychain" \
          >/dev/null 2>&1 || cleanup_status=$?
      fi
    elif [[ "$certificate_mutation_attempted" == true ]]; then
      cleanup_status=0
      "$security_tool" delete-certificate -Z "$certificate_sha256" -t "$keychain" \
        >/dev/null 2>&1 || cleanup_status=$?
    fi

    if [[ "$certificate_mutation_attempted" == true ]]; then
      certificate_lookup_status=0
      certificate_lookup_output="$("$security_tool" find-certificate -a \
        -c "$identity" -p "$keychain" 2>/dev/null)" \
        || certificate_lookup_status=$?
      case "$certificate_lookup_status" in
        0)
          certificate_lookup_count="$(certificate_pem_count \
            "$certificate_lookup_output")" || failed=true
          [[ "$certificate_lookup_count" == 0 ]] || failed=true
          ;;
        44) ;;
        *) failed=true ;;
      esac
    fi

    if [[ "$private_key_mutation_attempted" == true ]]; then
      private_key_lookup_status=0
      private_key_lookup_output="$("$security_tool" find-key -l "$identity" \
        -t private -s "$keychain" 2>&1)" || private_key_lookup_status=$?
      case "$private_key_lookup_status" in
        1)
          [[ "$private_key_lookup_output" == *"SecItemCopyMatching: The specified item could not be found in the keychain."* ]] \
            || failed=true
          ;;
        *) failed=true ;;
      esac
    fi

    if [[ "$trust_mutation_attempted" == true ]]; then
      trust_verification_status=0
      "$security_tool" verify-cert -c "$temporary/certificate.pem" \
        -p codeSign -L -R offline >/dev/null 2>&1 || trust_verification_status=$?
      [[ "$trust_verification_status" != 0 ]] || failed=true
    fi

    if [[ -n "$policy_temporary" && -e "$policy_temporary" ]]; then
      /bin/rm -f "$policy_temporary" || failed=true
    fi
    if [[ -n "$policy_property_list" && -e "$policy_property_list" ]]; then
      /bin/rm -f "$policy_property_list" || failed=true
    fi
    if [[ "$policy_publish_attempted" == true && -e "$policy" ]]; then
      observed_policy_inode="$(/usr/bin/stat -f '%i' "$policy" 2>/dev/null)" || failed=true
      if [[ -n "$policy_inode" && "$observed_policy_inode" == "$policy_inode" ]]; then
        /bin/rm -f "$policy" || failed=true
      else
        failed=true
      fi
    fi
    if [[ -n "$policy_staging_directory" && -d "$policy_staging_directory" ]]; then
      /bin/rmdir "$policy_staging_directory" || failed=true
    fi
    if [[ "$policy_root_created" == true && -d "$policy_root" ]]; then
      /bin/rmdir "$policy_root" || failed=true
    fi
  fi
  /bin/rm -rf "$temporary" || failed=true
  [[ "$failed" == false ]]
}

on_exit() {
  local exit_code="$1"
  trap - EXIT HUP INT TERM
  if ! cleanup; then
    print -u2 "ROLLBACK_FAILED"
    exit 70
  fi
  exit "$exit_code"
}

abort() {
  local message="$1"
  local exit_code="${2:-1}"
  print -u2 -- "$message"
  trap - EXIT HUP INT TERM
  if ! cleanup; then
    print -u2 "ROLLBACK_FAILED"
    exit 70
  fi
  exit "$exit_code"
}

trap 'on_exit $?' EXIT
trap 'abort "SIGNING_IDENTITY_INTERRUPTED:HUP" 129' HUP
trap 'abort "SIGNING_IDENTITY_INTERRUPTED:INT" 130' INT
trap 'abort "SIGNING_IDENTITY_INTERRUPTED:TERM" 143' TERM

existing_certificate_status=0
existing_certificate_output="$("$security_tool" find-certificate -a -c "$identity" \
  -p "$keychain" 2>&1)" || existing_certificate_status=$?
case "$existing_certificate_status" in
  0)
    existing_certificate_count="$(certificate_pem_count \
      "$existing_certificate_output")" \
      || abort "SIGNING_IDENTITY_LOOKUP_PARSE_FAILED" "$?"
    [[ "$existing_certificate_count" == 0 ]] \
      || abort "SIGNING_IDENTITY_ALREADY_EXISTS:$identity"
    ;;
  44) ;;
  *) abort "SIGNING_IDENTITY_LOOKUP_FAILED:$existing_certificate_status" \
    "$existing_certificate_status" ;;
esac
if [[ -e "$policy" ]]; then
  print -u2 "SIGNING_POLICY_ALREADY_EXISTS:$policy"
  exit 1
fi

/bin/chmod 0700 "$temporary"
/usr/bin/printf '%s\n' \
  '[req]' \
  'distinguished_name = subject' \
  'x509_extensions = code_signing' \
  'prompt = no' \
  '[subject]' \
  "CN = $identity" \
  'O = Local Development' \
  '[code_signing]' \
  'basicConstraints = critical,CA:FALSE' \
  'keyUsage = critical,digitalSignature' \
  'extendedKeyUsage = critical,codeSigning' \
  'subjectKeyIdentifier = hash' \
  'authorityKeyIdentifier = keyid' \
  > "$temporary/openssl.cnf"

/opt/homebrew/bin/openssl req -new -newkey rsa:3072 -nodes -x509 -sha256 -days 3650 \
  -config "$temporary/openssl.cnf" \
  -keyout "$temporary/private-key.pem" \
  -out "$temporary/certificate.pem" || abort "CERTIFICATE_GENERATION_FAILED" "$?"
/bin/chmod 0600 "$temporary/private-key.pem" || abort "PRIVATE_KEY_MODE_FAILED" "$?"

certificate_text="$(/opt/homebrew/bin/openssl x509 \
  -in "$temporary/certificate.pem" -noout -text)" \
  || abort "CERTIFICATE_INSPECTION_FAILED" "$?"
certificate_purposes="$(/opt/homebrew/bin/openssl x509 \
  -in "$temporary/certificate.pem" -noout -purpose)" \
  || abort "CERTIFICATE_PURPOSE_INSPECTION_FAILED" "$?"
[[ "$certificate_text" == *"Public-Key: (3072 bit)"* \
  && "$certificate_text" == *"Signature Algorithm: sha256WithRSAEncryption"* \
  && "$certificate_text" == *"CA:FALSE"* \
  && "$certificate_text" == *"Digital Signature"* \
  && "$certificate_text" == *"Code Signing"* ]] || {
  abort "CODE_SIGNING_CERTIFICATE_PROFILE_REQUIRED"
}
[[ "$certificate_text" != *"TLS Web Server Authentication"* \
  && "$certificate_text" != *"TLS Web Client Authentication"* ]] || {
  abort "TLS_EKU_FORBIDDEN"
}
[[ "$certificate_purposes" == *"SSL client : No"* \
  && "$certificate_purposes" == *"SSL server : No"* \
  && "$certificate_purposes" == *"Code signing : Yes"* ]] || {
  abort "CODE_SIGNING_CERTIFICATE_PURPOSE_REQUIRED"
}

key_password="$(/usr/bin/uuidgen)$(/usr/bin/uuidgen)"
/opt/homebrew/bin/openssl pkcs8 -topk8 \
  -v1 PBE-SHA1-3DES \
  -iter 2048 \
  -outform DER \
  -in "$temporary/private-key.pem" \
  -passout "pass:$key_password" \
  -out "$temporary/private-key.pk8" || abort "PKCS8_GENERATION_FAILED" "$?"
/bin/chmod 0600 "$temporary/private-key.pk8" || abort "PKCS8_MODE_FAILED" "$?"

pkcs8_text="$(/opt/homebrew/bin/openssl asn1parse -inform DER \
  -in "$temporary/private-key.pk8")" || abort "PKCS8_INSPECTION_FAILED" "$?"
[[ "$pkcs8_text" == *"pbeWithSHA1And3-KeyTripleDES-CBC"* ]] || {
  abort "SECURITY_IMPORT_COMPATIBLE_PKCS8_REQUIRED"
}

certificate_sha256="$(/opt/homebrew/bin/openssl x509 -in "$temporary/certificate.pem" \
  -noout -fingerprint -sha256 | /usr/bin/cut -d= -f2 | /usr/bin/tr -d ':' \
  | /usr/bin/tr '[:lower:]' '[:upper:]')" \
  || abort "CERTIFICATE_SHA256_FAILED" "$?"
certificate_sha1="$(/opt/homebrew/bin/openssl x509 -in "$temporary/certificate.pem" \
  -noout -fingerprint -sha1 | /usr/bin/cut -d= -f2 | /usr/bin/tr -d ':' \
  | /usr/bin/tr '[:lower:]' '[:upper:]')" \
  || abort "CERTIFICATE_SHA1_FAILED" "$?"
[[ "$certificate_sha256" =~ '^[0-9A-F]{64}$' \
  && "$certificate_sha1" =~ '^[0-9A-F]{40}$' ]] \
  || abort "CERTIFICATE_FINGERPRINT_INVALID"

certificate_mutation_attempted=true
"$security_tool" import "$temporary/certificate.pem" \
  -k "$keychain" \
  -f pemseq \
  -t cert || abort "CERTIFICATE_IMPORT_FAILED" "$?"
private_key_mutation_attempted=true
"$security_tool" import "$temporary/private-key.pk8" \
  -k "$keychain" \
  -f pkcs8 \
  -t priv \
  -P "$key_password" \
  -x \
  -T /usr/bin/codesign || abort "PRIVATE_KEY_IMPORT_FAILED" "$?"

certificate_output="$("$security_tool" find-certificate -a -c "$identity" \
  -p "$keychain")" || abort "IMPORTED_CERTIFICATE_QUERY_FAILED" "$?"
certificate_count="$(certificate_pem_count "$certificate_output")" \
  || abort "IMPORTED_CERTIFICATE_QUERY_FAILED" "$?"
[[ "$certificate_count" == 1 ]] || {
  abort "IMPORTED_CERTIFICATE_COUNT_INVALID:$certificate_count"
}
imported_certificate_pem="$("$security_tool" find-certificate -c "$identity" \
  -p "$keychain")" || abort "IMPORTED_CERTIFICATE_READBACK_FAILED" "$?"
imported_certificate_sha256="$(/usr/bin/printf '%s\n' "$imported_certificate_pem" \
  | /opt/homebrew/bin/openssl x509 -noout -fingerprint -sha256 \
  | /usr/bin/cut -d= -f2 | /usr/bin/tr -d ':' \
  | /usr/bin/tr '[:lower:]' '[:upper:]')" \
  || abort "IMPORTED_CERTIFICATE_SHA256_FAILED" "$?"
[[ "$imported_certificate_sha256" == "$certificate_sha256" ]] \
  || abort "IMPORTED_CERTIFICATE_FINGERPRINT_MISMATCH"

trust_mutation_attempted=true
"$command_supervisor" 300 "$security_tool" add-trusted-cert \
  -r trustRoot \
  -p codeSign \
  -k "$keychain" \
  "$temporary/certificate.pem" || abort "CODE_SIGN_TRUST_INSTALL_FAILED" "$?"

"$security_tool" verify-cert -c "$temporary/certificate.pem" \
  -p codeSign -L -R offline || abort "CODE_SIGN_TRUST_VERIFICATION_FAILED" "$?"

/usr/bin/printf '%s\n' 'int main(void) { return 0; }' \
  > "$temporary/signing-probe.c" || abort "SIGNING_PROBE_SOURCE_WRITE_FAILED" "$?"
/usr/bin/xcrun clang "$temporary/signing-probe.c" -o "$temporary/signing-probe" \
  || abort "SIGNING_PROBE_BUILD_FAILED" "$?"
/usr/bin/perl -e 'alarm shift @ARGV; exec @ARGV or exit 127' 15 \
  /usr/bin/codesign --force --sign "$certificate_sha1" \
  --keychain "$keychain" --timestamp=none "$temporary/signing-probe" \
  || abort "SIGNING_PROBE_SIGN_FAILED" "$?"
/usr/bin/perl -e 'alarm shift @ARGV; exec @ARGV or exit 127' 15 \
  /usr/bin/codesign --verify --strict --verbose=2 "$temporary/signing-probe" \
  || abort "SIGNING_PROBE_VERIFY_FAILED" "$?"

if [[ -e "$policy_root" ]]; then
  [[ -d "$policy_root" && ! -L "$policy_root" \
    && "$(/usr/bin/stat -f '%u' "$policy_root")" == "$(/usr/bin/id -u)" \
    && "$(/usr/bin/stat -f '%Lp' "$policy_root")" == 700 ]] \
    || abort "SIGNING_POLICY_ROOT_UNSAFE"
else
  /bin/mkdir -m 0700 "$policy_root" || abort "SIGNING_POLICY_ROOT_CREATE_FAILED" "$?"
  policy_root_created=true
fi
policy_staging_directory="$(/usr/bin/mktemp -d "$policy_root/.signing-policy.XXXXXX")" \
  || abort "SIGNING_POLICY_TEMP_CREATE_FAILED" "$?"
/bin/chmod 0700 "$policy_staging_directory" || abort "SIGNING_POLICY_MODE_FAILED" "$?"
policy_property_list="$policy_staging_directory/signing-policy.plist"
policy_temporary="$policy_staging_directory/signing-policy.json"
/usr/bin/plutil -create xml1 "$policy_property_list" || abort "SIGNING_POLICY_CREATE_FAILED" "$?"
/bin/chmod 0600 "$policy_property_list" || abort "SIGNING_POLICY_MODE_FAILED" "$?"
/usr/bin/plutil -insert schema_version -integer 1 "$policy_property_list" || abort "SIGNING_POLICY_WRITE_FAILED" "$?"
/usr/bin/plutil -insert identity -string "$identity" "$policy_property_list" || abort "SIGNING_POLICY_WRITE_FAILED" "$?"
/usr/bin/plutil -insert certificate_sha256 -string "$certificate_sha256" "$policy_property_list" || abort "SIGNING_POLICY_WRITE_FAILED" "$?"
/usr/bin/plutil -insert certificate_sha1 -string "$certificate_sha1" "$policy_property_list" || abort "SIGNING_POLICY_WRITE_FAILED" "$?"
/usr/bin/plutil -insert keychain -string "$keychain" "$policy_property_list" || abort "SIGNING_POLICY_WRITE_FAILED" "$?"
/usr/bin/plutil -insert private_key_exported -bool false "$policy_property_list" || abort "SIGNING_POLICY_WRITE_FAILED" "$?"
/usr/bin/plutil -insert private_key_extractable -bool false "$policy_property_list" || abort "SIGNING_POLICY_WRITE_FAILED" "$?"
/usr/bin/plutil -insert private_key_never_extractable -bool true "$policy_property_list" || abort "SIGNING_POLICY_WRITE_FAILED" "$?"
/usr/bin/plutil -insert import_format -string "pkcs8-der" "$policy_property_list" || abort "SIGNING_POLICY_WRITE_FAILED" "$?"
/usr/bin/plutil -insert codesign_verified -bool true "$policy_property_list" || abort "SIGNING_POLICY_WRITE_FAILED" "$?"
/usr/bin/plutil -convert json -o "$policy_temporary" "$policy_property_list" \
  || abort "SIGNING_POLICY_CONVERSION_FAILED" "$?"
/bin/chmod 0600 "$policy_temporary" || abort "SIGNING_POLICY_MODE_FAILED" "$?"
policy_output="$(/usr/bin/plutil -p "$policy_temporary")" \
  || abort "SIGNING_POLICY_READBACK_FAILED" "$?"
policy_inode="$(/usr/bin/stat -f '%i' "$policy_temporary")" \
  || abort "SIGNING_POLICY_INODE_FAILED" "$?"
policy_publish_attempted=true
/bin/ln "$policy_temporary" "$policy" || abort "SIGNING_POLICY_PUBLISH_FAILED" "$?"
/bin/rm -f "$policy_temporary" || abort "SIGNING_POLICY_TEMP_REMOVE_FAILED" "$?"
policy_temporary=""
/bin/rm -f "$policy_property_list" || abort "SIGNING_POLICY_TEMP_REMOVE_FAILED" "$?"
policy_property_list=""
/bin/rmdir "$policy_staging_directory" || abort "SIGNING_POLICY_TEMP_REMOVE_FAILED" "$?"
policy_staging_directory=""
identity_committed=true
/usr/bin/printf 'SIGNING_IDENTITY_READY:%s\n' "$certificate_sha256"
/usr/bin/printf '%s\n' "$policy_output"
