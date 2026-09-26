#!/bin/bash
# Build and sign a STAGING artifact, verify its code identity, and record a
# manifest tying the source revision to the exact bytes that were signed.
#
#   ./scripts/stage-release.sh                       # Developer ID (default)
#   MACOS_CLI_SIGN_MODE=adhoc ./scripts/stage-release.sh
#   ./scripts/stage-release.sh --allow-dirty
#
# The staging artifact is written to dist/staging/ and is deliberately NOT
# installed anywhere: this script never copies onto PATH, never loads a
# LaunchAgent, and never grants a permission.
#
# The manifest records the git revision, the as-built (pre-codesign) hash, the
# final signed hash, the embedded Info.plist digest, and the resulting
# designated requirement. It contains no secrets: no certificate hashes, no
# Keychain material, no private data. The signing identity appears only as its
# public label (which already contains the public Team ID).
#
# WHAT THE MANIFEST DOES AND DOES NOT PROVE
#   Clean tree: the recorded revision identifies the source the bytes were built
#   from, and `source_reconstructible` is true.
#   Dirty tree (--allow-dirty): the source is NOT reconstructible from this
#   manifest. It records digests of what the working tree contained — a SHA-256
#   of `git diff HEAD` and a SHA-256 over the sorted (digest, path) index of
#   every untracked non-ignored file — plus the diff and index as sidecar files.
#   Those let you check later whether a tree matches; they do not let you
#   rebuild it, so `source_reconstructible` is false and no claim is made that
#   the artifact is tied to a committed revision.
#
# Reproducibility note: the *procedure* is reproducible; the signed bytes are
# not bit-identical between runs, because a Developer ID signature embeds an
# RFC-3161 secure timestamp. Compare `as_built_sha256` across runs to check the
# build itself, and use `signed_sha256` to identify one specific signed artifact.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/sign_verify.sh
source "$REPO_ROOT/scripts/lib/sign_verify.sh"

PRODUCT_NAME="macos-cli"
STAGE_DIR="$REPO_ROOT/dist/staging"
ALLOW_DIRTY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --allow-dirty) ALLOW_DIRTY=1 ;;
        -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) sv_err "unknown argument: $1"; exit 2 ;;
    esac
    shift
done

cd "$REPO_ROOT"

echo "macos-cli staging build"
echo "======================="
echo ""

# ── Provenance ───────────────────────────────────────────────────────────────
git_revision="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
git_short="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"

# Deterministic digests of whatever the working tree actually holds. On a clean
# tree the diff is empty and there are no untracked files, so these are fixed
# constants; on a dirty tree they change with every edit to either half.
read -r tracked_diff_sha256 untracked_sha256 untracked_count <<EOF
$(sv_source_state_digests)
EOF

if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    git_dirty=true
    source_reconstructible=false
    if [ "$ALLOW_DIRTY" != 1 ]; then
        sv_err "❌  Working tree is dirty; a staging manifest would not identify a real revision."
        sv_err "    Commit/stash, or re-run with --allow-dirty to record the dirty-source digests."
        exit 1
    fi
    echo "⚠️   Working tree is dirty — the manifest will identify these bytes but NOT a"
    echo "     reconstructible source revision. Recording tracked-diff and untracked digests."
else
    git_dirty=false
    source_reconstructible=true
fi

# ── Signing configuration (explicit, no silent fallback) ─────────────────────
sv_load_sign_config
echo "🔏  Signing mode: $SV_SIGN_MODE"
[ "$SV_SIGN_MODE" = "developer-id" ] && echo "    Identity: $SV_SIGN_IDENTITY"

# ── Build ────────────────────────────────────────────────────────────────────
echo "🔨  Building release..."
swift build -c release >/dev/null
BIN_PATH="$(swift build -c release --show-bin-path)"
BUILT_BINARY="$BIN_PATH/$PRODUCT_NAME"
[ -x "$BUILT_BINARY" ] || { sv_err "❌  product not found at $BUILT_BINARY"; exit 1; }

as_built_sha256="$(sv_sha256 "$BUILT_BINARY")"
echo "✅  as-built sha256: $as_built_sha256"
echo "    (arm64 links carry a linker-generated ad-hoc signature; this is the"
echo "     hash of the compiler output before our codesign pass.)"

# ── Stage + sign a copy; the build output itself is left alone ───────────────
# Every file here is created exclusively (mktemp, mode 0600) and only then moved
# onto its deterministic published name, so a pre-planted symlink at a
# predictable path in dist/staging cannot capture the copy or the signing.
mkdir -p "$STAGE_DIR"
STAGED="$STAGE_DIR/${PRODUCT_NAME}-${git_short}"
STAGED_TMP="$(sv_stage_temp "$STAGE_DIR" ".${PRODUCT_NAME}-${git_short}.stage")"
trap 'rm -f "$STAGED_TMP" 2>/dev/null' EXIT

# Move TMP onto FINAL, refusing a destination that is not a regular file.
stage_publish() {   # stage_publish TMP FINAL
    local tmp="$1" final="$2"
    if [ -e "$final" ] || [ -L "$final" ]; then
        sv_assert_regular_file "$final" || return 1
    fi
    mv -f "$tmp" "$final"
}

cat "$BUILT_BINARY" > "$STAGED_TMP"
chmod +x "$STAGED_TMP"

echo "🔎  Verifying embedded Info.plist..."
sv_verify_info_plist "$STAGED_TMP" "$SV_EXPECTED_VERSION"
PLIST_TMP="$(sv_stage_temp "$STAGE_DIR" ".${PRODUCT_NAME}-${git_short}.plist")"
sv_extract_info_plist "$STAGED_TMP" "$PLIST_TMP"
info_plist_sha256="$(sv_sha256 "$PLIST_TMP")"
stage_publish "$PLIST_TMP" "$STAGE_DIR/${PRODUCT_NAME}-${git_short}-Info.plist"

echo "🔏  Signing staging artifact..."
sv_sign_binary "$STAGED_TMP" "$SV_SIGN_MODE" "$SV_SIGN_IDENTITY"

echo "🔎  Verifying signature, identity, entitlements and version..."
sv_verify_signature "$STAGED_TMP" "$SV_SIGN_MODE"
sv_verify_info_plist "$STAGED_TMP" "$SV_EXPECTED_VERSION"
sv_verify_version "$STAGED_TMP" "$SV_EXPECTED_VERSION"

# Publish under the deterministic name by same-directory rename.
sv_atomic_install "$STAGED_TMP" "$STAGED"
trap - EXIT

# ── Dirty-source sidecars ────────────────────────────────────────────────────
if [ "$git_dirty" = true ]; then
    DIRTY_PATCH_TMP="$(sv_stage_temp "$STAGE_DIR" ".${PRODUCT_NAME}-${git_short}.patch")"
    git diff HEAD > "$DIRTY_PATCH_TMP"
    stage_publish "$DIRTY_PATCH_TMP" "$STAGE_DIR/${PRODUCT_NAME}-${git_short}-dirty.patch"

    UNTRACKED_TMP="$(sv_stage_temp "$STAGE_DIR" ".${PRODUCT_NAME}-${git_short}.untracked")"
    sv_untracked_source_index > "$UNTRACKED_TMP"
    stage_publish "$UNTRACKED_TMP" "$STAGE_DIR/${PRODUCT_NAME}-${git_short}-untracked-index.txt"
fi

signed_sha256="$(sv_sha256 "$STAGED")"
designated_requirement="$(sv_designated_requirement "$STAGED")"
team_identifier="$(sv_team_identifier "$STAGED")"
cdhash="$(sv_cdhash "$STAGED")"
swift_ver="$(swift --version 2>&1 | head -1)"
timestamp_utc="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# ── Manifest ─────────────────────────────────────────────────────────────────
# Built as a property list and converted by plutil's own JSON writer. The
# designated requirement and the identity label are attacker- or
# certificate-controlled text full of quotes and backslashes; hand-escaping them
# into a heredoc is how a provenance record ends up unparseable or wrong.
MANIFEST="$STAGE_DIR/${PRODUCT_NAME}-${git_short}-staging.json"
MANIFEST_PLIST="$(sv_stage_temp "$STAGE_DIR" ".${PRODUCT_NAME}-${git_short}.manifest-plist")"
MANIFEST_TMP="$(sv_stage_temp "$STAGE_DIR" ".${PRODUCT_NAME}-${git_short}.manifest-json")"
trap 'rm -f "$MANIFEST_PLIST" "$MANIFEST_TMP" 2>/dev/null' EXIT

if [ "$git_dirty" = true ]; then
    source_note="Working tree was dirty. This manifest identifies the signed bytes and digests of the working-tree state (see the -dirty.patch and -untracked-index.txt sidecars); it does NOT identify a reconstructible source revision."
else
    source_note="Working tree was clean; the recorded git revision identifies the source these bytes were built from."
fi

sv_manifest_begin "$MANIFEST_PLIST"
sv_manifest_set "$MANIFEST_PLIST" manifest_version          integer 2
sv_manifest_set "$MANIFEST_PLIST" product                   string  "$PRODUCT_NAME"
sv_manifest_set "$MANIFEST_PLIST" version                   string  "$SV_EXPECTED_VERSION"
sv_manifest_set "$MANIFEST_PLIST" bundle_identifier         string  "$SV_BUNDLE_ID"
sv_manifest_set "$MANIFEST_PLIST" git_revision              string  "$git_revision"
sv_manifest_set "$MANIFEST_PLIST" git_dirty                 bool    "$git_dirty"
sv_manifest_set "$MANIFEST_PLIST" git_tracked_diff_sha256   string  "$tracked_diff_sha256"
sv_manifest_set "$MANIFEST_PLIST" git_untracked_sha256      string  "$untracked_sha256"
sv_manifest_set "$MANIFEST_PLIST" git_untracked_file_count  integer "$untracked_count"
sv_manifest_set "$MANIFEST_PLIST" source_reconstructible    bool    "$source_reconstructible"
sv_manifest_set "$MANIFEST_PLIST" source_note               string  "$source_note"
sv_manifest_set "$MANIFEST_PLIST" staged_at_utc             string  "$timestamp_utc"
sv_manifest_set "$MANIFEST_PLIST" toolchain                 string  "$swift_ver"
sv_manifest_set "$MANIFEST_PLIST" as_built_sha256           string  "$as_built_sha256"
sv_manifest_set "$MANIFEST_PLIST" info_plist_sha256         string  "$info_plist_sha256"
sv_manifest_set "$MANIFEST_PLIST" signed_sha256             string  "$signed_sha256"
sv_manifest_set "$MANIFEST_PLIST" signed_artifact           string  "dist/staging/$(basename "$STAGED")"
sv_manifest_set "$MANIFEST_PLIST" sign_mode                 string  "$SV_SIGN_MODE"
sv_manifest_set "$MANIFEST_PLIST" sign_identity_label       string  "$SV_SIGN_IDENTITY"
sv_manifest_set "$MANIFEST_PLIST" team_identifier           string  "$team_identifier"
sv_manifest_set "$MANIFEST_PLIST" cdhash                    string  "$cdhash"
sv_manifest_set "$MANIFEST_PLIST" designated_requirement    string  "$designated_requirement"
sv_manifest_set "$MANIFEST_PLIST" entitlements              string  "$(sv_entitlement_keys "$STAGED" | xargs)"
sv_manifest_set "$MANIFEST_PLIST" installed                 bool    false
sv_manifest_set "$MANIFEST_PLIST" notarized                 bool    false
sv_manifest_set "$MANIFEST_PLIST" notes                     string  "Staging artifact only — not installed, not notarized, not stapled. Contains no secrets: no certificate hashes, no keychain material."

if [ "$git_dirty" = true ]; then
    sv_manifest_set "$MANIFEST_PLIST" dirty_patch string "dist/staging/${PRODUCT_NAME}-${git_short}-dirty.patch"
    sv_manifest_set "$MANIFEST_PLIST" dirty_untracked_index string "dist/staging/${PRODUCT_NAME}-${git_short}-untracked-index.txt"
fi

sv_manifest_write_json "$MANIFEST_PLIST" "$MANIFEST_TMP"
rm -f "$MANIFEST_PLIST"
stage_publish "$MANIFEST_TMP" "$MANIFEST"
trap - EXIT

echo ""
echo "✅  Staging artifact: dist/staging/$(basename "$STAGED")"
echo "✅  Manifest:         dist/staging/$(basename "$MANIFEST")"
echo ""
cat "$MANIFEST"
echo ""
echo "This artifact was NOT installed. Nothing was added to your PATH."
