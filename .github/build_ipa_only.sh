#!/bin/sh
#
# build_ipa_only.sh
#
# xcarchive から「素の LiveContainer.ipa」を作る。
#
# 本家 `.github/build_github.sh` の前半に相当する。SideStore 同梱版は
# 続けて `build_sidestore_ipa.sh` が作るので、このスクリプトは
# **Payload/ を消さずに残す**。SideStoreSupport.framework も
# 一時退避するだけで、最後に必ず戻す (同梱版が必要とするため)。
#
# 必要な環境変数:
#   archive_path : xcodebuild archive の -archivePath (拡張子なし)
#   scheme       : 出力する IPA の名前 (通常 LiveContainer)
#
set -e

: "${archive_path:?archive_path が未設定です}"
: "${scheme:?scheme が未設定です}"

ARCHIVE="$archive_path.xcarchive"

if [ ! -d "$ARCHIVE" ]; then
    echo "::error::$ARCHIVE が見つかりません"
    exit 1
fi

echo "=== xcarchive の中身 ==="
ls -la "$ARCHIVE/Products/Applications"

# Applications ディレクトリをそのまま Payload にする (本家と同じ手順)
if [ ! -d Payload ]; then
    mv "$ARCHIVE/Products/Applications" Payload
fi

APP="Payload/LiveContainer.app"

# SideStoreSupport.framework は SideStore 同梱版でのみ使う。
# 素の IPA には含めないが、**消さずに退避**して後で戻す。
mkdir -p tmp
if [ -d "$APP/Frameworks/SideStoreSupport.framework" ]; then
    echo "=== SideStoreSupport.framework を一時退避します ==="
    mv "$APP/Frameworks/SideStoreSupport.framework" ./tmp/
fi

echo "=== フォーク追加分の確認 (ビルド後の Info.plist) ==="
/usr/libexec/PlistBuddy -c "Print :NSAlarmKitUsageDescription" "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Print :NSBonjourServices" "$APP/Info.plist" \
    | grep "_FC9F5ED42C8A._tcp" || {
        echo "::error::ビルド後の Info.plist に Quick Share のサービスタイプがありません"
        exit 1
    }

zip -qr "$scheme.ipa" "Payload" -x "._*" -x ".DS_Store" -x "__MACOSX"

# 同梱版が使うので必ず戻す
if [ -d "./tmp/SideStoreSupport.framework" ]; then
    mv ./tmp/SideStoreSupport.framework "$APP/Frameworks/"
    echo "=== SideStoreSupport.framework を戻しました ==="
fi

echo "=== 出来上がった IPA ==="
ls -lh "$scheme.ipa"
unzip -l "$scheme.ipa" | tail -3
