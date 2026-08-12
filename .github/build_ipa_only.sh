#!/bin/sh
#
# build_ipa_only.sh
#
# `.github/build_github.sh` の「素の LiveContainer.ipa を作る」部分だけを
# 抜き出したもの。SideStore を同梱する後半 (dylibify / ldid / SideStore.ipa の
# ダウンロード) は行わない。
#
# 本家スクリプトは外部バイナリのダウンロードと SideStore の nightly 取得に
# 依存しており、そこが落ちるとフォークでは原因が分かりにくい。IPA を
# 手元でビルドして SideStore で入れ直すだけなら、このスクリプトで足りる。
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
mv "$ARCHIVE/Products/Applications" Payload

# SideStoreSupport.framework は SideStore 同梱版でのみ使うもので、
# 素の IPA には含めない。本家スクリプトも zip の前に一時退避している。
if [ -d "Payload/LiveContainer.app/Frameworks/SideStoreSupport.framework" ]; then
    echo "=== SideStoreSupport.framework を除外します ==="
    rm -rf "Payload/LiveContainer.app/Frameworks/SideStoreSupport.framework"
fi

echo "=== Bonjour 許可リストの確認 ==="
/usr/libexec/PlistBuddy -c "Print :NSBonjourServices" \
    "Payload/LiveContainer.app/Info.plist" || true

zip -qr "$scheme.ipa" "Payload" -x "._*" -x ".DS_Store" -x "__MACOSX"

echo "=== 出来上がった IPA ==="
ls -lh "$scheme.ipa"
unzip -l "$scheme.ipa" | tail -3
