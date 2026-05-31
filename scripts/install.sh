#!/usr/bin/env bash
#
# Dusty installer. Builds the app from source on your machine and drops it in
# /Applications. Because the build happens locally, macOS trusts it: no
# Gatekeeper warnings, no "unidentified developer", no right-click dance.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/yagcioglutoprak/dusty/main/scripts/install.sh | bash
#
# Environment overrides:
#   DUSTY_PREFIX   install location (default: /Applications)
#   DUSTY_REF      git ref to build (default: main)
#
set -euo pipefail

REPO_URL="https://github.com/yagcioglutoprak/dusty.git"
REF="${DUSTY_REF:-main}"
REF_EXPLICIT="${DUSTY_REF:+yes}"   # non-empty only when the user set DUSTY_REF
PREFIX="${DUSTY_PREFIX:-/Applications}"
APP_NAME="Dusty.app"

bold=$(tput bold 2>/dev/null || true)
dim=$(tput dim 2>/dev/null || true)
red=$(tput setaf 1 2>/dev/null || true)
green=$(tput setaf 2 2>/dev/null || true)
reset=$(tput sgr0 2>/dev/null || true)

say()  { printf "%s\n" "${dim}dusty${reset} $*"; }
ok()   { printf "%s\n" "${green}ok${reset}    $*"; }
die()  { printf "%s\n" "${red}error${reset} $*" >&2; exit 1; }

printf "\n%s\n%s\n\n" "${bold}Dusty${reset}" "${dim}Free up disk space on your Mac, safely.${reset}"

# Preflight ------------------------------------------------------------------

[ "$(uname -s)" = "Darwin" ] || die "Dusty is macOS only."

if ! command -v git >/dev/null 2>&1; then
  die "git not found. Install the Xcode Command Line Tools with: xcode-select --install"
fi

# Building a SwiftUI app needs the full Xcode, not just the command line tools.
if ! command -v xcodebuild >/dev/null 2>&1; then
  die "xcodebuild not found. Install Xcode from the App Store, then run:
       sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
fi

DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
case "$DEV_DIR" in
  *CommandLineTools*)
    die "Xcode is required to build Dusty, but the active toolchain is the Command Line Tools.
       Install Xcode, then point the toolchain at it:
       sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" ;;
esac

XCODE_MAJOR="$(xcodebuild -version 2>/dev/null | awk 'NR==1{split($2,v,"."); print v[1]}')"
if [ -n "$XCODE_MAJOR" ] && [ "$XCODE_MAJOR" -lt 16 ] 2>/dev/null; then
  die "Dusty's project needs Xcode 16 or later (found $XCODE_MAJOR). Update Xcode from the App Store."
fi

# Build ----------------------------------------------------------------------

WORK="$(mktemp -d -t dusty)"
trap 'rm -rf "$WORK"' EXIT

say "fetching source (${REF})"
if [ -n "${REF_EXPLICIT:-}" ]; then
  # An explicitly requested DUSTY_REF must resolve. Do not silently build a
  # different ref: a typo should fail loudly, not install something unexpected.
  git clone --depth 1 --branch "$REF" "$REPO_URL" "$WORK/dusty" >/dev/null 2>&1 \
    || die "could not fetch ref '$REF' (set via DUSTY_REF). Check the name, or unset DUSTY_REF to build the default branch."
else
  git clone --depth 1 --branch "$REF" "$REPO_URL" "$WORK/dusty" >/dev/null 2>&1 \
    || git clone --depth 1 "$REPO_URL" "$WORK/dusty" >/dev/null 2>&1 \
    || die "could not clone $REPO_URL"
fi

cd "$WORK/dusty/Dusty"

# The committed Xcode project is the happy path. Regenerate only if it is gone.
if [ ! -d "Dusty.xcodeproj" ]; then
  if ! command -v xcodegen >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
      say "installing xcodegen (needed to generate the project)"
      brew install xcodegen >/dev/null
    else
      die "Dusty.xcodeproj is missing and neither xcodegen nor Homebrew is installed."
    fi
  fi
  xcodegen generate >/dev/null
fi

say "building (this takes a minute on first run)"
DERIVED="$WORK/DerivedData"
xcodebuild \
  -project Dusty.xcodeproj \
  -scheme Dusty \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="-" \
  DEVELOPMENT_TEAM="" \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGNING_ALLOWED=YES \
  build >/dev/null 2>"$WORK/build.log" \
  || { tail -30 "$WORK/build.log" >&2; die "build failed (log above)"; }

BUILT="$DERIVED/Build/Products/Release/$APP_NAME"
[ -d "$BUILT" ] || die "build finished but $APP_NAME was not found"

# Install --------------------------------------------------------------------
#
# Stage the freshly built app beside the destination on the same volume, then
# swap it into place. The previous install is kept as a backup until the new
# copy is confirmed, so a failed copy never leaves you without a working app.

DEST="$PREFIX/$APP_NAME"
STAGING="$PREFIX/.dusty-install-$$.app"
BACKUP="$PREFIX/.dusty-backup-$$.app"

_sudo_noted=""
run_priv() {
  # Run a filesystem command, retrying once with sudo if it fails (e.g. /Applications needs admin).
  if "$@" 2>/dev/null; then
    return 0
  fi
  if [ -z "$_sudo_noted" ]; then
    say "writing to $PREFIX needs admin rights"
    _sudo_noted=1
  fi
  sudo "$@"
}

# Clean up staging/backup on any exit, in addition to the build dir.
cleanup_install() { run_priv rm -rf "$STAGING" "$BACKUP" >/dev/null 2>&1 || true; }
trap 'cleanup_install; rm -rf "$WORK"' EXIT

say "installing to $PREFIX"
run_priv rm -rf "$STAGING"
if ! run_priv ditto "$BUILT" "$STAGING"; then
  run_priv rm -rf "$STAGING"
  die "could not stage the new build in $PREFIX"
fi
[ -d "$STAGING" ] || die "build staged but $STAGING is missing"

if [ -d "$DEST" ]; then
  say "replacing existing install at $DEST"
  run_priv rm -rf "$BACKUP"
  run_priv mv "$DEST" "$BACKUP"
fi

if run_priv mv "$STAGING" "$DEST"; then
  run_priv rm -rf "$BACKUP"
else
  if [ -d "$BACKUP" ]; then
    run_priv mv "$BACKUP" "$DEST"
    die "could not install to $DEST; the previous version was restored"
  fi
  die "could not install to $DEST"
fi

# Locally built apps are not quarantined, but strip the flag just in case.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

ok "installed $DEST"
printf "\n"
say "launching Dusty. Look for the disk icon in your menu bar."
say "for the deepest scan, grant Full Disk Access in System Settings > Privacy & Security."
open "$DEST" || true
printf "\n"
