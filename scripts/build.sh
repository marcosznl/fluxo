#!/bin/zsh
# Compila e monta dist/Speedtest.app (assinatura ad-hoc, para uso local).
# Uso: scripts/build.sh [--install]   (--install copia para ~/Applications e abre)
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release

APP=dist/Speedtest.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Speedtest "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"

# O ícone faz parte do projeto (Resources/AppIcon.icns). Para redesenhar: scripts/make-icon.sh
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

codesign --force --sign - "$APP"
echo "Pronto: $APP"

if [[ "${1:-}" == "--install" ]]; then
    mkdir -p ~/Applications
    pkill -x Speedtest 2>/dev/null || true
    rm -rf ~/Applications/Speedtest.app
    cp -R "$APP" ~/Applications/
    open ~/Applications/Speedtest.app
    echo "Instalado em ~/Applications/Speedtest.app"
fi
