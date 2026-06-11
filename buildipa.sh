#!/bin/bash
set -e  # stoppe le script si une commande échoue

# ─── Config ────────────────────────────────────────────────────
SCHEME="TwitchUnblock"
WORKSPACE="TwitchUnblock.xcodeproj"   # ou TwitchUnblock.xcworkspace si tu as des SPM packages
CONFIGURATION="Release"
SDK="iphoneos"
DERIVED_DATA="build/DerivedData"
OUTPUT_DIR="build"
APP_NAME="TwitchUnblock"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🟣 TwitchUnblock — Build IPA"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ─── Xcode version ─────────────────────────────────────────────
echo "▶ Xcode : $(xcodebuild -version | head -1)"
echo "▶ SDK   : $(xcodebuild -showsdks | grep iphoneos | tail -1)"

# ─── Clean build dir ───────────────────────────────────────────
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

# ─── Build (sans signature — AltStore re-signe à l'install) ────
echo ""
echo "▶ Compilation Release arm64..."

xcodebuild \
  -project "$WORKSPACE" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -sdk "$SDK" \
  -derivedDataPath "$DERIVED_DATA" \
  -destination "generic/platform=iOS" \
  ONLY_ACTIVE_ARCH=NO \
  ARCHS="arm64" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  DEVELOPMENT_TEAM="" \
  | xcpretty --color 2>/dev/null || cat   # affiche les logs bruts si xcpretty absent

# ─── Localiser le .app ─────────────────────────────────────────
APP_PATH=$(find "$DERIVED_DATA/Build/Products/$CONFIGURATION-$SDK" \
  -name "$APP_NAME.app" -maxdepth 1 | head -1)

if [ -z "$APP_PATH" ]; then
  echo "❌ Erreur : $APP_NAME.app introuvable dans $DERIVED_DATA"
  exit 1
fi

echo "✅ .app trouvé : $APP_PATH"

# ─── Packager en IPA ───────────────────────────────────────────
echo ""
echo "▶ Création du .ipa..."

PAYLOAD_DIR="$OUTPUT_DIR/Payload"
mkdir -p "$PAYLOAD_DIR"
cp -r "$APP_PATH" "$PAYLOAD_DIR/"

cd "$OUTPUT_DIR"
zip -r "$APP_NAME.ipa" Payload/ -x "*.DS_Store"
cd ..

rm -rf "$OUTPUT_DIR/Payload"

# ─── Résultat ──────────────────────────────────────────────────
IPA_SIZE=$(du -sh "$OUTPUT_DIR/$APP_NAME.ipa" | cut -f1)
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ IPA généré : $OUTPUT_DIR/$APP_NAME.ipa ($IPA_SIZE)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
