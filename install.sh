#!/usr/bin/env bash
# Install PDF to Images to /Applications for Launchpad + Spotlight presence.
set -euo pipefail
cd "$(dirname "$0")"

exec ./scripts/install.sh
