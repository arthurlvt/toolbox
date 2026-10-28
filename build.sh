#!/bin/bash
# Compile Toolbox, crée l'appli « Toolbox.app » et installe la commande « pdftool ».
#   ./build.sh              → compile + installe dans ~/Applications et ~/.local/bin
#   ./build.sh --no-install → compile seulement (résultat dans ./build)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Toolbox"
INSTALL=1
[[ "${1:-}" == "--no-install" ]] && INSTALL=0

if ! command -v swift >/dev/null 2>&1; then
  echo "✗ Swift est introuvable. Installe les outils de développement Apple :"
  echo "    xcode-select --install"
  exit 1
fi

# La compilation se fait hors du dossier (souvent synchronisé par Nextcloud / iCloud,
# qui corrompt la base de compilation en la copiant pendant qu'elle s'écrit).
SCRATCH="$HOME/Library/Caches/fr.arthur.toolbox/build"
mkdir -p "$SCRATCH"
rm -rf .build    # ancien dossier de compilation dans le projet, plus utilisé

echo "→ Compilation (release)…"
swift build -c release --scratch-path "$SCRATCH"
BIN="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)"

echo "→ Assemblage de ${APP_NAME}.app…"
APP="build/${APP_NAME}.app"
rm -rf "$APP" "build/PDF Toolbox.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Toolbox" "$APP/Contents/MacOS/Toolbox"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN/pdftool" build/pdftool
echo "→ Tests des calculs (calculatrice, notes, planning, casque)…"
if ! "$APP/Contents/MacOS/Toolbox" --selftest; then
  echo "⚠︎ Des tests ont échoué (détail ci-dessus) : l'appli est quand même installée, mais dis-le à Claude."
fi
# Signature ad hoc : suffisant pour lancer l'appli sur ton propre Mac.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

if [[ $INSTALL -eq 1 ]]; then
  mkdir -p "$HOME/Applications" "$HOME/.local/bin"
  # Ancienne version (avant le renommage).
  if [[ -d "$HOME/Applications/PDF Toolbox.app" ]]; then
    pkill -x PDFToolbox 2>/dev/null || true
    rm -rf "$HOME/Applications/PDF Toolbox.app"
    echo "✓ Ancienne appli « PDF Toolbox » supprimée"
  fi
  pkill -x Toolbox 2>/dev/null || true
  rm -rf "$HOME/Applications/${APP_NAME}.app"
  cp -R "$APP" "$HOME/Applications/"
  touch "$HOME/Applications/${APP_NAME}.app"   # force le Finder et le Dock à relire l'icône
  cp build/pdftool "$HOME/.local/bin/pdftool"

  # Déclare l'appli au système : « Ouvrir avec » + Services du clic droit.
  LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  [[ -x "$LSREGISTER" ]] && "$LSREGISTER" -f "$HOME/Applications/${APP_NAME}.app" >/dev/null 2>&1 || true
  /System/Library/CoreServices/pbs -update >/dev/null 2>&1 || true

  echo "✓ Appli installée : ~/Applications/${APP_NAME}.app (cherche « Toolbox » dans Spotlight)"
  echo "✓ Commande installée : ~/.local/bin/pdftool"
  echo "✓ Clic droit sur un PDF dans le Finder → Services → « Toolbox : … »"
  if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    echo
    echo "ℹ︎ Pour utiliser « pdftool » partout, ajoute cette ligne à ~/.zshrc puis rouvre le terminal :"
    echo '    export PATH="$HOME/.local/bin:$PATH"'
  fi
  open "$HOME/Applications/${APP_NAME}.app"
else
  echo "✓ Résultat dans ./build"
fi

# Outils optionnels
command -v gs >/dev/null 2>&1 || [[ -x /opt/homebrew/bin/gs ]] || \
  echo "ℹ︎ Optionnel, pour une meilleure compression : brew install ghostscript"
[[ -x /Library/TeX/texbin/latexmk ]] || command -v latexmk >/dev/null 2>&1 || \
  echo "ℹ︎ Pour l'onglet LaTeX : brew install --cask mactex-no-gui"
