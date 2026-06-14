#!/usr/bin/env bash
#
# Build a release zip for the Radio Browser LMS plugin and print the SHA1
# that must go into repo.xml's <sha> element.
#
# Usage:  ./build.sh
#
# Produces:  dist/RadioBrowser-<version>.zip
#
set -euo pipefail

cd "$(dirname "$0")"

PLUGIN_DIR="RadioBrowser"
INSTALL_XML="$PLUGIN_DIR/install.xml"

# Read the version straight from install.xml so it can never drift.
VERSION="$(sed -n 's:.*<version>\(.*\)</version>.*:\1:p' "$INSTALL_XML")"
if [[ -z "$VERSION" ]]; then
	echo "ERROR: could not read <version> from $INSTALL_XML" >&2
	exit 1
fi

ZIP="dist/${PLUGIN_DIR}-${VERSION}.zip"

mkdir -p dist
rm -f "$ZIP"

# Zip the plugin folder at top level so it extracts to Plugins/RadioBrowser/.
# Exclude editor/OS cruft.
zip -r "$ZIP" "$PLUGIN_DIR" \
	-x '*.DS_Store' -x '*/.*' >/dev/null

# SHA1 of the archive (LMS verifies this against repo.xml).
if command -v sha1sum >/dev/null; then
	SHA="$(sha1sum "$ZIP" | awk '{print $1}')"
else
	SHA="$(shasum -a 1 "$ZIP" | awk '{print $1}')"
fi

echo "Built:   $ZIP"
echo "Version: $VERSION"
echo "SHA1:    $SHA"
echo
echo "Next steps:"
echo "  1. Upload $ZIP to the GitHub release tagged v${VERSION}."
echo "  2. Set <sha>${SHA}</sha> and the matching <url> in repo.xml."
