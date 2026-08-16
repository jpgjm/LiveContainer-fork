#!/bin/sh
#
# build_sidestore_ipa.sh
#
# `build_ipa_only.sh` が残した Payload/ をもとに、SideStore 同梱版
# (LiveContainer+SideStore.ipa) を作る。
#
# 本家 `.github/build_github.sh` の後半に相当する。フォーク向けに次を変えている:
#   - wget ではなく curl を使う (ランナーに wget が無い場合がある)
#   - ダウンロードの成否を明示的に検査する (失敗を握り潰さない)
#   - Settings.bundle への追記を固定インデックスではなく末尾追加にする
#     (本家は :PreferenceSpecifiers:3 に決め打ちしているが、実際の要素数と
#      合わないと PlistBuddy が失敗する)
#   - 各段階で成果物の存在を確認し、欠けていたらそこで止める
#
# SideStore は「ホストアプリ」ではなく**内蔵ゲストアプリ**として同梱される。
# 実行ファイルを dylibify で dylib 化し、LiveContainer.app/Frameworks/ に
# SideStoreApp.framework として置く。ただし URL スキーム・App Intents・
# ウィジェット拡張は**ホストの Info.plist / PlugIns に焼き込む**。
# ゲスト側からはこれらを登録できないため。
#
# 必要な環境変数:
#   scheme : 出力名のもとになる名前 (通常 LiveContainer)
#
set -e

: "${scheme:?scheme が未設定です}"

APP="Payload/LiveContainer.app"
DYLIBIFY_URL="https://github.com/LiveContainer/dylibify/releases/download/1.0/dylibify"
SIDESTORE_URL="https://github.com/LiveContainer/SideStore/releases/download/nightly/SideStore.ipa"

if [ ! -d "$APP" ]; then
    echo "::error::$APP がありません。先に build_ipa_only.sh を実行してください"
    exit 1
fi
if [ ! -d "$APP/Frameworks/SideStoreSupport.framework" ]; then
    echo "::error::SideStoreSupport.framework が $APP/Frameworks にありません"
    echo "build_ipa_only.sh が退避したまま戻していない可能性があります"
    exit 1
fi

# --- 外部ツールの取得 -------------------------------------------------
echo "=== dylibify を取得します ==="
curl -fsSL -o dylibify "$DYLIBIFY_URL"
chmod +x dylibify
file dylibify

echo "=== ldid を導入します ==="
if command -v ldid >/dev/null 2>&1; then
    echo "ldid は導入済みです"
else
    brew install ldid
fi
ldid -v 2>&1 | head -1 || true

# --- ホスト側 Info.plist に SideStore 関連のキーを焼き込む -------------
echo "=== Info.plist に SideStore のキーを追加します ==="
PB=/usr/libexec/PlistBuddy
PLIST="$APP/Info.plist"

$PB -c 'Add :ALTAppGroups array' "$PLIST"
$PB -c 'Add :ALTAppGroups: string group.com.SideStore.SideStore' "$PLIST"

# CFBundleURLTypes は既に livecontainer 用が 1 件入っている。その後ろに足す。
$PB -c "Add :CFBundleURLTypes:1 dict" "$PLIST"
$PB -c "Add :CFBundleURLTypes:1:CFBundleURLName string com.kdt.livecontainer.sidestoreurlscheme" "$PLIST"
$PB -c "Add :CFBundleURLTypes:1:CFBundleURLSchemes array" "$PLIST"
$PB -c "Add :CFBundleURLTypes:1:CFBundleURLSchemes:0 string sidestore" "$PLIST"
$PB -c "Add :CFBundleURLTypes:2 dict" "$PLIST"
$PB -c "Add :CFBundleURLTypes:2:CFBundleURLName string com.kdt.livecontainer.sidestorebackupurlscheme" "$PLIST"
$PB -c "Add :CFBundleURLTypes:2:CFBundleURLSchemes array" "$PLIST"
$PB -c "Add :CFBundleURLTypes:2:CFBundleURLSchemes:0 string sidestore-com.kdt.livecontainer" "$PLIST"

$PB -c "Add :INIntentsSupported array" "$PLIST"
$PB -c "Add :INIntentsSupported:0 string RefreshAllIntent" "$PLIST"
$PB -c "Add :INIntentsSupported:1 string ViewAppIntent" "$PLIST"
$PB -c "Add :NSUserActivityTypes array" "$PLIST"
$PB -c "Add :NSUserActivityTypes:0 string RefreshAllIntent" "$PLIST"
$PB -c "Add :NSUserActivityTypes:1 string ViewAppIntent" "$PLIST"

# --- Settings.bundle に「Open SideStore」トグルを足す ------------------
# 本家は :PreferenceSpecifiers:3 に決め打ちしているが、実際の要素数と
# 合わないと PlistBuddy が失敗する。末尾に追加する形にしておく。
echo "=== Settings.bundle にトグルを追加します ==="
ROOT="$APP/Settings.bundle/Root.plist"
if [ -f "$ROOT" ]; then
    python3 - "$ROOT" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, 'rb') as f:
    data = plistlib.load(f)
specs = data.setdefault('PreferenceSpecifiers', [])
if not any(s.get('Key') == 'LCOpenSideStore' for s in specs):
    specs.append({
        'Type': 'PSToggleSwitchSpecifier',
        'Title': 'Open SideStore',
        'Key': 'LCOpenSideStore',
        'DefaultValue': False,
    })
    with open(path, 'wb') as f:
        plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)
    print(f'追加しました (現在 {len(specs)} 項目)')
else:
    print('既に存在します')
PY
else
    echo "::warning::$ROOT がないためトグルの追加をスキップします"
fi

# --- SideStore を取得して内蔵ゲストアプリに仕立てる --------------------
echo "=== SideStore.ipa を取得します ==="
mkdir -p tmp
curl -fsSL -o tmp/SideStore.ipa "$SIDESTORE_URL"
ls -lh tmp/SideStore.ipa
( cd tmp && unzip -q -o SideStore.ipa )

if [ ! -d tmp/Payload/SideStore.app ]; then
    echo "::error::tmp/Payload/SideStore.app が見つかりません"
    ls -la tmp/Payload 2>/dev/null || true
    exit 1
fi

SSAPP="$APP/Frameworks/SideStoreApp.framework"
mv tmp/Payload/SideStore.app "$SSAPP"

echo "=== 実行ファイルを dylib 化します ==="
./dylibify "$SSAPP/SideStore" "$SSAPP/SideStore.dylib"
rm "$SSAPP/SideStore"
mv "$SSAPP/SideStore.dylib" "$SSAPP/SideStore"
ldid -S"" "$SSAPP/SideStore"

# ゲストアプリとしてのメタデータ (固定 UUID / 署名しない / TweakLoader 不要)
cp ./.github/sidelc/LCAppInfo.plist "$SSAPP/"

# --- App Intents をホスト側に移植 -------------------------------------
# ゲストの Metadata.appintents は installd に登録されないため、
# ホストのバンドル直下に置く。実装は SideStoreSupport.framework 側にあるので、
# Swift のマングル名に含まれるモジュール名を書き換える (数字は文字数)。
echo "=== App Intents をホストに移植します ==="
cp "$SSAPP/Intents.intentdefinition" "$APP/"
cp "$SSAPP/ViewApp.intentdefinition" "$APP/"
cp -r "$SSAPP/Metadata.appintents" "$APP/Metadata.appintents"

ACTIONS="$APP/Metadata.appintents/extract.actionsdata"
if [ ! -f "$ACTIONS" ]; then
    echo "::error::$ACTIONS がありません"
    exit 1
fi

# 置換前に対象の文字列が存在するか確かめる。
# SideStore nightly の内部構成が変わってマングル名が変わると、sed は
# 黙って何もしない。その場合 Metadata.appintents は存在しない型を指したままになり、
# Refresh All Apps が実行時に失敗する (症状が分かりにくい)。
for pat in 9SideStore20RefreshAllAppsIntentV 9SideStore26RefreshAllAppsWidgetIntentV; do
    if ! grep -q "$pat" "$ACTIONS"; then
        echo "::error::$pat が extract.actionsdata に見つかりません"
        echo "SideStore nightly のマングル名が変わった可能性があります。実際の値:"
        strings "$ACTIONS" | grep -o '"mangledTypeNameV2":"[^"]*"' | sort -u
        exit 1
    fi
done

sed -i '' 's/9SideStore20RefreshAllAppsIntentV/16SideStoreSupport20RefreshAllAppsIntentV/g' "$ACTIONS"
sed -i '' 's/9SideStore26RefreshAllAppsWidgetIntentV/16SideStoreSupport26RefreshAllAppsWidgetIntentV/g' "$ACTIONS"

# 置換後の確認。公式 nightly (3.8.6) では次の 2 つになっている。
#   "mangledTypeNameV2":"16SideStoreSupport20RefreshAllAppsIntentV"
#   "mangledTypeNameV2":"16SideStoreSupport26RefreshAllAppsWidgetIntentV"
echo "置換後のマングル名:"
strings "$ACTIONS" | grep -o '"mangledTypeNameV2":"[^"]*RefreshAll[^"]*"' | sort -u
for pat in 16SideStoreSupport20RefreshAllAppsIntentV 16SideStoreSupport26RefreshAllAppsWidgetIntentV; do
    if ! grep -q "$pat" "$ACTIONS"; then
        echo "::error::置換に失敗しました ($pat)"
        exit 1
    fi
done
echo "マングル名を書き換えました"

# --- ウィジェット拡張をホストの PlugIns に移す -------------------------
echo "=== ウィジェット拡張を移植します ==="
mkdir -p "$APP/PlugIns"
if [ ! -d "$SSAPP/PlugIns/AltWidgetExtension.appex" ]; then
    echo "::error::AltWidgetExtension.appex が見つかりません"
    ls -la "$SSAPP/PlugIns" 2>/dev/null || true
    exit 1
fi
WIDGET="$APP/PlugIns/LiveWidgetExtension.appex"
mv "$SSAPP/PlugIns/AltWidgetExtension.appex" "$WIDGET"
cp -r "$SSAPP/Frameworks" "$WIDGET/"
$PB -c "Set :CFBundleIdentifier com.kdt.livecontainer.LiveWidget" "$WIDGET/Info.plist"
$PB -c "Set :CFBundleExecutable LiveWidgetExtension" "$WIDGET/Info.plist"
mv "$WIDGET/AltWidgetExtension" "$WIDGET/LiveWidgetExtension"

# --- 署名まわりの後始末 -----------------------------------------------
# 本家 build_github.sh はここで次の 2 行を実行している。
#
#   rm -r .zsign_cache
#   find payloadlc/Payload -type d -name "_CodeSignature" -exec rm -r {} +
#
# `payloadlc/Payload` は存在しないパスなので、**2 行目は実質的に何もしない**。
# 以前このフォークでは「本家のバグ」と判断して `Payload` に直していたが、
# それは誤りだった。公式の +SideStore.ipa を展開して確認したところ、
# `_CodeSignature` は 11 個すべて**残ったまま配布されている**。
#
#   Payload/LiveContainer.app/_CodeSignature
#   Payload/LiveContainer.app/PlugIns/LiveProcess.appex/_CodeSignature
#   ...
#
# つまり「消さない」のが正しい状態。勝手に消すと、SideStore で
# 再署名したときに拡張の登録が壊れる可能性がある
# (Refresh All Apps が LiveProcess.appex を NSExtension として起こせなくなる)。
#
# ここでは本家の意図どおり `.zsign_cache` だけを消す。
rm -rf .zsign_cache

ldid -S.github/sidelc/LiveWidgetExtension_adhoc.xml "$WIDGET/LiveWidgetExtension"

# --- 最終確認 ----------------------------------------------------------
echo "=== 同梱版の内容を確認します ==="
FAILED=0
for p in \
    "$SSAPP/SideStore" \
    "$SSAPP/LCAppInfo.plist" \
    "$APP/Metadata.appintents/extract.actionsdata" \
    "$WIDGET/LiveWidgetExtension" \
    "$APP/Frameworks/SideStoreSupport.framework"
do
    if [ -e "$p" ]; then
        echo "  OK  $p"
    else
        echo "::error::欠落 $p"
        FAILED=1
    fi
done

# dylib 化が効いているか (MH_DYLIB になっているか) を確かめる
if file "$SSAPP/SideStore" | grep -q "dynamically linked shared library"; then
    echo "  OK  SideStore は dylib 化されています"
else
    echo "::error::SideStore が dylib になっていません"
    file "$SSAPP/SideStore"
    FAILED=1
fi

# _CodeSignature が残っているか。
# 公式の +SideStore.ipa には 11 個入っている。0 個なら、どこかで
# 消してしまっている (拡張の登録が壊れる恐れがある)。
CS_COUNT=$(find Payload -type d -name "_CodeSignature" | wc -l | tr -d ' ')
echo "  --  _CodeSignature: $CS_COUNT 個 (公式は 11 個)"
if [ "$CS_COUNT" -eq 0 ]; then
    echo "::error::_CodeSignature が 1 つも残っていません"
    FAILED=1
fi

# 拡張が揃っているか。Refresh All Apps は LiveProcess.appex を
# NSExtension として起こすので、これが無いと動かない。
for ext in LiveProcess.appex ShareExtension.appex LaunchAppExtension.appex LiveWidgetExtension.appex; do
    if [ -d "$APP/PlugIns/$ext" ]; then
        echo "  OK  PlugIns/$ext"
    else
        echo "::error::PlugIns/$ext がありません"
        FAILED=1
    fi
done

# フォーク追加分が同梱版にも残っているか
$PB -c "Print :NSAlarmKitUsageDescription" "$PLIST" >/dev/null 2>&1 \
    && echo "  OK  NSAlarmKitUsageDescription" \
    || { echo "::error::NSAlarmKitUsageDescription が消えています"; FAILED=1; }

$PB -c "Print :NSBonjourServices" "$PLIST" | grep -q "_FC9F5ED42C8A._tcp" \
    && echo "  OK  Quick Share のサービスタイプ" \
    || { echo "::error::Quick Share のサービスタイプが消えています"; FAILED=1; }

[ "$FAILED" -eq 0 ] || exit 1

zip -qr "$scheme+SideStore.ipa" "Payload" -x "._*" -x ".DS_Store" -x "__MACOSX"

echo "=== 出来上がった IPA ==="
ls -lh "$scheme+SideStore.ipa"
