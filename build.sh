#!/bin/bash
# Compila NotchIsland y crea build/NotchIsland.app (firma ad-hoc, solo para tu Mac).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release "$@"

mkdir -p build
APP="build/NotchIsland.app"
STAGING_DIR="$(mktemp -d "build/.NotchIsland.XXXXXX")"
STAGED_APP="$STAGING_DIR/NotchIsland.app"
PREVIOUS_APP="$STAGING_DIR/Previous.app"

cleanup() {
    local status=$?
    trap - EXIT
    if (( status != 0 )) && [[ -e "$PREVIOUS_APP" && ! -e "$APP" ]]; then
        if ! mv "$PREVIOUS_APP" "$APP"; then
            echo "No se pudo restaurar la app anterior. Está en: $PREVIOUS_APP" >&2
            return
        fi
    fi
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$STAGED_APP/Contents/MacOS"
cp ".build/release/NotchIsland" "$STAGED_APP/Contents/MacOS/NotchIsland"
cp Info.plist "$STAGED_APP/Contents/Info.plist"
# Firma estable: con tu cuenta de desarrollador de Apple (Xcode > Ajustes > Cuentas) la identidad de la app
# no cambia entre compilaciones, así que macOS recuerda los permisos (Spotify/Música, calendario,
# recordatorios, ubicación, cámara, Bluetooth…). Sin cuenta se firma "ad hoc" y habría que volver a
# concederlos tras cada compilación. Se puede forzar otra identidad con NOTCH_SIGN_IDENTITY.
SIGN_IDENTITY="${NOTCH_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "Firmando con: $SIGN_IDENTITY"
    codesign --force --deep --sign "$SIGN_IDENTITY" "$STAGED_APP"
else
    echo "Sin cuenta de desarrollador: firma ad hoc (los permisos se pedirán de nuevo tras cada compilación)"
    codesign --force --deep --sign - "$STAGED_APP"
fi
codesign --verify --deep --strict "$STAGED_APP"

# Solo sustituimos la app instalada cuando la nueva ya está completa y firmada.
if [[ -e "$APP" ]]; then
    mv "$APP" "$PREVIOUS_APP"
fi
mv "$STAGED_APP" "$APP"

echo ""
echo "Listo: $APP"
echo "Ábrela con:  open $APP"
