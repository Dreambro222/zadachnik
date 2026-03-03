#!/bin/zsh
# Сборка и запуск Задачник без Xcode

set -e

PROJECT="/Users/cek/Desktop/Задачник/Задачник.xcodeproj"
SCHEME="Zadachnik"
APP_PATH="/Users/cek/Library/Developer/Xcode/DerivedData/Задачник-gwkyfptahtcergbpzukuwftoiror/Build/Products/Debug/Задачник.app"

echo "🔨 Собираю Задачник..."
xcodebuild -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "platform=macOS,arch=arm64" \
  -configuration Debug \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_ENTITLEMENTS="" \
  DEVELOPMENT_TEAM="" \
  build | grep -E "(error:|warning:|BUILD SUCCEEDED|BUILD FAILED)" || true

echo "🚀 Запускаю..."
open "$APP_PATH"
echo "✅ Готово!"
