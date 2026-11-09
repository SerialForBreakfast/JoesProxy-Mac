#!/bin/zsh

set -euo pipefail

LABEL="${1:-JoesProxy Root CA}"
LOGIN_KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

echo "JoesProxy trust-flow audit"
echo "Label: ${LABEL}"
echo "Keychain: ${LOGIN_KEYCHAIN}"
echo

if security find-certificate -a -c "${LABEL}" "${LOGIN_KEYCHAIN}" >/dev/null 2>&1; then
    echo "Unsafe to run manual validation in this account."
    echo "A certificate with label '${LABEL}' already exists in the login keychain."
    echo
    echo "Recommended action:"
    echo "- switch to a disposable macOS user account before running the manual trust-flow playbook"
    echo "- or remove the existing certificate only if you explicitly intend to replace it"
    exit 1
fi

echo "No existing '${LABEL}' certificate was found in the login keychain."
echo "This account is clear for the documented manual validation flow."
echo
echo "Next step:"
echo "- follow memlog/TrustFlowManualValidation.md"
