#!/bin/zsh
# Redesenha o ícone do app (desenhado em código em Sources/Fluxo/GaugeIcon.swift)
# e grava Resources/AppIcon.iconset e Resources/AppIcon.icns.
set -euo pipefail
cd "${0:A:h}/.."

swift build
rm -rf Resources/AppIcon.iconset
.build/debug/Fluxo --gerar-icone Resources/AppIcon.iconset
iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
echo "Ícone salvo em Resources/AppIcon.icns"
