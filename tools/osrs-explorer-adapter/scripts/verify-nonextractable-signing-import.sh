#!/bin/zsh -f
set -euo pipefail
umask 077
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

inject_keychain_create_failure=false
case "${1:-}" in
  "") ;;
  --probe-keychain-create-failure) inject_keychain_create_failure=true ;;
  *) print -u2 "USAGE: $0 [--probe-keychain-create-failure]"; exit 64 ;;
esac

identity="OSRS Explorer Adapter Nonextractable Signing Probe"
openssl="/opt/homebrew/bin/openssl"
security="/usr/bin/security"
temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/osrs-adapter-signing-import-probe.XXXXXX")"
keychain="$temporary/probe.keychain-db"
keychain_password="$(/usr/bin/uuidgen)$(/usr/bin/uuidgen)"
key_password="$(/usr/bin/uuidgen)$(/usr/bin/uuidgen)"
original_search_list="$($security list-keychains -d user)"

cleanup() {
  $security delete-keychain "$keychain" >/dev/null 2>&1 || true
  /bin/rm -rf "$temporary"
}
trap cleanup EXIT

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

$openssl req -new -newkey rsa:3072 -nodes -x509 -sha256 -days 3650 \
  -config "$temporary/openssl.cnf" \
  -keyout "$temporary/private-key.pem" \
  -out "$temporary/certificate.pem" >/dev/null 2>&1
/bin/chmod 0600 "$temporary/private-key.pem"

certificate_text="$($openssl x509 -in "$temporary/certificate.pem" -noout -text)"
certificate_purposes="$($openssl x509 -in "$temporary/certificate.pem" -noout -purpose)"
[[ "$certificate_text" == *"Public-Key: (3072 bit)"* \
  && "$certificate_text" == *"Signature Algorithm: sha256WithRSAEncryption"* \
  && "$certificate_text" == *"CA:FALSE"* \
  && "$certificate_text" == *"Digital Signature"* \
  && "$certificate_text" == *"Code Signing"* ]] || {
  print -u2 "PROBE_CERTIFICATE_PROFILE_MISMATCH"
  exit 1
}
[[ "$certificate_text" != *"TLS Web Server Authentication"* \
  && "$certificate_text" != *"TLS Web Client Authentication"* ]] || {
  print -u2 "PROBE_TLS_EKU_FORBIDDEN"
  exit 1
}
[[ "$certificate_purposes" == *"SSL client : No"* \
  && "$certificate_purposes" == *"SSL server : No"* \
  && "$certificate_purposes" == *"Code signing : Yes"* ]] || {
  print -u2 "PROBE_CERTIFICATE_PURPOSE_MISMATCH"
  exit 1
}

$openssl pkcs8 -topk8 \
  -v1 PBE-SHA1-3DES \
  -iter 2048 \
  -outform DER \
  -in "$temporary/private-key.pem" \
  -passout "pass:$key_password" \
  -out "$temporary/private-key.pk8"
/bin/chmod 0600 "$temporary/private-key.pk8"

pkcs8_text="$($openssl asn1parse -inform DER -in "$temporary/private-key.pk8")"
[[ "$pkcs8_text" == *"pbeWithSHA1And3-KeyTripleDES-CBC"* ]] || {
  print -u2 "PROBE_PKCS8_PROFILE_MISMATCH"
  exit 1
}

create_probe_keychain() {
  run_keychain_step create \
    $security create-keychain -p "$keychain_password" "$keychain" || {
    exit_code=$?
    cleanup
    return "$exit_code"
  }
  run_keychain_step settings \
    $security set-keychain-settings -lut 3600 "$keychain" || {
    exit_code=$?
    cleanup
    return "$exit_code"
  }
  run_keychain_step unlock \
    $security unlock-keychain -p "$keychain_password" "$keychain" || {
    exit_code=$?
    cleanup
    return "$exit_code"
  }
}

run_keychain_step() {
  local step="$1"
  shift
  if [[ "$inject_keychain_create_failure" == true && "$step" == create ]]; then
    print -u2 "PROBE_INJECTED_KEYCHAIN_CREATE_FAILURE"
    return 206
  fi
  "$@"
}

create_probe_keychain
$security import "$temporary/certificate.pem" \
  -k "$keychain" \
  -f pemseq \
  -t cert >/dev/null
$security import "$temporary/private-key.pk8" \
  -k "$keychain" \
  -f pkcs8 \
  -t priv \
  -P "$key_password" \
  -x \
  -T /usr/bin/codesign >/dev/null

certificate_count="$($security find-certificate -a -c "$identity" -p "$keychain" \
  | /usr/bin/grep -c 'BEGIN CERTIFICATE')"
[[ "$certificate_count" == 1 ]] || {
  print -u2 "PROBE_IMPORTED_CERTIFICATE_COUNT_INVALID:$certificate_count"
  exit 1
}
identity_output="$($security find-identity -p codesigning "$keychain")"
[[ "$identity_output" == *"1 identities found"* \
  && "$identity_output" == *"$identity"* ]] || {
  print -u2 "PROBE_IMPORTED_CODE_SIGNING_IDENTITY_INVALID"
  print -u2 -- "$identity_output"
  exit 1
}
$security find-key -t private -s "$keychain" >/dev/null

acl="$($security dump-keychain -a "$keychain" 2>&1)"
[[ "$acl" == *"/usr/bin/codesign"* ]] || {
  print -u2 "PROBE_CODESIGN_ACL_MISSING"
  exit 1
}
[[ "$acl" == *"0x00000010 <uint32>=0x00000000"* \
  && "$acl" == *"0x00000011 <uint32>=0x00000001"* ]] || {
  print -u2 "PROBE_PRIVATE_KEY_REMAINS_EXTRACTABLE"
  exit 1
}
application_paths="$(/usr/bin/printf '%s\n' "$acl" \
  | /usr/bin/grep -E '^[[:space:]]+[0-9]+: /' || true)"
[[ "$(/usr/bin/printf '%s\n' "$application_paths" \
  | /usr/bin/grep -c '^ *0: /usr/bin/codesign (OK)$')" == 1 \
  && "$(/usr/bin/printf '%s\n' "$application_paths" | /usr/bin/wc -l | /usr/bin/tr -d ' ')" == 1 ]] || {
  print -u2 "PROBE_CODESIGN_ACL_NOT_EXCLUSIVE"
  exit 1
}

$security delete-keychain "$keychain"
[[ "$($security list-keychains -d user)" == "$original_search_list" ]] || {
  print -u2 "PROBE_USER_KEYCHAIN_SEARCH_LIST_CHANGED"
  exit 1
}

/usr/bin/printf '%s\n' \
  '{"status":"NONEXTRACTABLE_SIGNING_IMPORT_VERIFIED","explicit_format":"pkcs8-der","rsa_bits":3072,"certificate_signature":"sha256WithRSAEncryption","private_key_encryption":"PBE-SHA1-3DES","iterations":2048,"private_key_extractable":false,"private_key_never_extractable":true,"identity_pair_verified":true,"allowed_application":"/usr/bin/codesign","codesign_verification":"deferred_until_code-sign-only-trust","ssl_client":false,"ssl_server":false,"user_keychain_search_list_unchanged":true}'
