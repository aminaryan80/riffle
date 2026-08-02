#!/bin/bash
# Builds Riffle and installs it to /Applications, then launches it.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

echo "==> Stopping any running instance…"
pkill -x Riffle 2>/dev/null || true

echo "==> Installing to /Applications…"
rm -rf /Applications/Riffle.app
cp -R dist/Riffle.app /Applications/

echo "==> Launching…"
open /Applications/Riffle.app

cat <<'EOF'

Installed!

  If this is the first install with the "Riffle Dev" signing certificate,
  grant Accessibility once when macOS prompts (System Settings > Privacy &
  Security > Accessibility > enable "Riffle"). The grant now persists across
  updates — no need to re-enable it again.

Then hold Cmd and press Tab (active screen) or ` (all screens).
EOF
