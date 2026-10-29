#!/bin/bash
# Crée « build/Toolbox-<version>.dmg » à partir de build/Toolbox.app (lance ./build.sh avant).
# Le .dmg contient l'appli et un raccourci vers Applications : on glisse l'une sur l'autre.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Toolbox.app"
if [[ ! -d "${APP}" ]]; then
  echo "✗ ${APP} introuvable : lance d'abord ./build.sh"
  exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP}/Contents/Info.plist" 2>/dev/null || echo "1.0")
DMG="build/Toolbox-${VERSION}.dmg"
STAGE=$(mktemp -d)

echo "→ Préparation…"
cp -R "${APP}" "${STAGE}/"
ln -s /Applications "${STAGE}/Applications"
xattr -cr "${STAGE}/Toolbox.app" 2>/dev/null || true
codesign --force --deep --sign - "${STAGE}/Toolbox.app" >/dev/null 2>&1 || true

echo "→ Création de ${DMG}…"
rm -f "${DMG}"
hdiutil create -volname "Toolbox" -srcfolder "${STAGE}" -ov -format UDZO -fs HFS+ "${DMG}" >/dev/null
rm -rf "${STAGE}"

SIZE=$(du -h "${DMG}" | cut -f1)
echo "✓ ${DMG} (${SIZE})"
echo "  Sur un autre Mac : ouvre le .dmg, glisse Toolbox dans Applications,"
echo "  puis la 1re fois clic droit sur Toolbox → Ouvrir (appli non signée par Apple)."
