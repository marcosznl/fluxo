#!/bin/zsh
# Compila o app e o widget com o Xcode (assinados com a equipe do projeto) e monta
# dist/Fluxo.app. Uso: scripts/build.sh [--install]   (--install copia para ~/Applications e abre)
set -euo pipefail
cd "${0:A:h}/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

xcodebuild -project Fluxo.xcodeproj -target Fluxo -configuration Release \
    SYMROOT=.build/xcode -allowProvisioningUpdates -quiet build

rm -rf dist/Fluxo.app
mkdir -p dist
cp -R .build/xcode/Release/Fluxo.app dist/
echo "Pronto: dist/Fluxo.app"

if [[ "${1:-}" == "--install" ]]; then
    mkdir -p ~/Applications
    pkill -x Fluxo 2>/dev/null || true
    rm -rf ~/Applications/Fluxo.app
    cp -R dist/Fluxo.app ~/Applications/
    open ~/Applications/Fluxo.app
    echo "Instalado em ~/Applications/Fluxo.app"
fi
