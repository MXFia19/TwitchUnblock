#!/bin/bash
set -e

# ─── Config ────────────────────────────────────────────────────
SCHEME="TwitchUnblock"
WORKSPACE="TwitchUnblock.xcodeproj"
CONFIGURATION="Release"
DERIVED_DATA="build/DerivedData-Catalyst"
OUTPUT_DIR="build"
APP_NAME="TwitchUnblock"
DMG_NAME="TwitchUnblock-Catalyst"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🟣 TwitchUnblock — Build Mac Catalyst DMG"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo "▶ Xcode : $(xcodebuild -version | head -1)"

mkdir -p "$OUTPUT_DIR"

# ─── Build Mac Catalyst ─────────────────────────────────────────
echo ""
echo "▶ Compilation Mac Catalyst..."

xcodebuild \
  -project "$WORKSPACE" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "platform=macOS,variant=Mac Catalyst" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  DEVELOPMENT_TEAM="" \
  SUPPORTS_MACCATALYST=YES \
  | xcpretty --color 2>/dev/null || cat

# ─── Localiser le .app ─────────────────────────────────────────
APP_PATH=$(find "$DERIVED_DATA/Build/Products/$CONFIGURATION-maccatalyst" \
  -name "$APP_NAME.app" -maxdepth 1 | head -1)

if [ -z "$APP_PATH" ]; then
  echo "❌ Erreur : $APP_NAME.app (Catalyst) introuvable"
  exit 1
fi

echo "✅ .app trouvé : $APP_PATH"

# ─── Créer le DMG ──────────────────────────────────────────────
echo ""
echo "▶ Création du .dmg..."

STAGING="$OUTPUT_DIR/dmg-staging"
mkdir -p "$STAGING"
cp -r "$APP_PATH" "$STAGING/"

# Lien symbolique vers /Applications (pratique dans le DMG)
ln -sf /Applications "$STAGING/Applications"

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$OUTPUT_DIR/$DMG_NAME.dmg"

rm -rf "$STAGING"

# ─── Résultat ──────────────────────────────────────────────────
DMG_SIZE=$(du -sh "$OUTPUT_DIR/$DMG_NAME.dmg" | cut -f1)
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ DMG généré : $OUTPUT_DIR/$DMG_NAME.dmg ($DMG_SIZE)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
