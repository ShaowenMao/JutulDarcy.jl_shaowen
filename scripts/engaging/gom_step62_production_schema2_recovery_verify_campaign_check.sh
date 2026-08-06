#!/bin/bash
# Verify a source campaign-check result without relying on optional summary fields.

set -euo pipefail

check_root="${1:?Usage: $0 CHECK_ROOT CAMPAIGN_MANIFEST SHA256 PHYSICS_PROFILE}"
campaign_manifest="${2:?Usage: $0 CHECK_ROOT CAMPAIGN_MANIFEST SHA256 PHYSICS_PROFILE}"
expected_sha256="${3:?Usage: $0 CHECK_ROOT CAMPAIGN_MANIFEST SHA256 PHYSICS_PROFILE}"
physics_profile="${4:?Usage: $0 CHECK_ROOT CAMPAIGN_MANIFEST SHA256 PHYSICS_PROFILE}"

[[ "$expected_sha256" =~ ^[0-9a-f]{64}$ ]]
test -f "$check_root/PASS"
test -s "$check_root/campaign_check_summary.txt"
test -s "$check_root/campaign.toml"
test -s "$check_root/campaign.toml.sha256"
test -s "$campaign_manifest"
grep -Fxq 'status=pass' "$check_root/campaign_check_summary.txt"
grep -Fxq "physics_profile=$physics_profile" \
    "$check_root/campaign_check_summary.txt"

# Schema-2 campaign checks created before this verifier did not record the
# manifest digest in campaign_check_summary.txt.  The archived manifest copy
# and its checksum are the authoritative, backward-compatible proof.
cmp -s "$campaign_manifest" "$check_root/campaign.toml"
observed_sha256="$(sha256sum "$check_root/campaign.toml" | awk '{print $1}')"
test "$observed_sha256" = "$expected_sha256"
(
    cd "$check_root"
    sha256sum --check campaign.toml.sha256 >/dev/null
)
