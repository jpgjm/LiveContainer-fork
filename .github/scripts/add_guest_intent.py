#!/usr/bin/env python3
"""
LiveContainer.xcodeproj/project.pbxproj に LCGuestIntent.swift を
LiveContainer (アプリ) ターゲットの Sources ビルドフェーズへ追加する。

Xcode を開かずに済ませるためのスクリプト。CI の中で走らせる想定。
何度実行しても結果は変わらない (idempotent)。

なぜアプリターゲットなのか:
  LiveActivityIntent は「アプリのプロセス」で実行される仕様なので、
  Apple の指示どおり型はアプリターゲットに置く必要がある。
  LiveContainerSwiftUI は dlopen されるフレームワークで、
  AppIntents のメタデータがアプリ側に統合されないため使えない。

sourceTree に SOURCE_ROOT を使う理由:
  グループ (PBXGroup) への登録を省けるので、pbxproj への変更が
  最小の 3 箇所で済む。xcodebuild はグループ所属を見ない。
"""

import os
import re
import sys

PBXPROJ = "LiveContainer.xcodeproj/project.pbxproj"

# LiveContainer アプリターゲットの Sources ビルドフェーズ ID
SOURCES_PHASE_ID = "17DCE9992C7067EC00731D42"

# 追加するファイル
FILE_PATH = "LiveContainer/LCGuestIntent.swift"
FILE_NAME = "LCGuestIntent.swift"

# 衝突しない固定 UUID (24 桁 hex)
BUILD_FILE_ID = "AC1A2B3C4D5E6F7089ABCDE1"
FILE_REF_ID = "AC1A2B3C4D5E6F7089ABCDE2"


def fail(message: str) -> None:
    print(f"::error::{message}")
    sys.exit(1)


def main() -> None:
    if not os.path.exists(PBXPROJ):
        fail(f"{PBXPROJ} が見つかりません。リポジトリのルートで実行してください。")

    if not os.path.exists(FILE_PATH):
        fail(f"{FILE_PATH} が見つかりません。先にファイルを配置してください。")

    with open(PBXPROJ, "r", encoding="utf-8") as f:
        text = f.read()

    if BUILD_FILE_ID in text:
        print("既に追加済みです。何もしません。")
        return

    original_length = len(text)

    # 1. PBXBuildFile セクションへ追加
    build_file_entry = (
        f"\t\t{BUILD_FILE_ID} /* {FILE_NAME} in Sources */ = "
        f"{{isa = PBXBuildFile; fileRef = {FILE_REF_ID} /* {FILE_NAME} */; }};\n"
    )
    marker = "/* Begin PBXBuildFile section */\n"
    if marker not in text:
        fail("PBXBuildFile セクションが見つかりません。")
    text = text.replace(marker, marker + build_file_entry, 1)

    # 2. PBXFileReference セクションへ追加
    file_ref_entry = (
        f"\t\t{FILE_REF_ID} /* {FILE_NAME} */ = "
        f"{{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; "
        f'name = {FILE_NAME}; path = "{FILE_PATH}"; sourceTree = SOURCE_ROOT; }};\n'
    )
    marker = "/* Begin PBXFileReference section */\n"
    if marker not in text:
        fail("PBXFileReference セクションが見つかりません。")
    text = text.replace(marker, marker + file_ref_entry, 1)

    # 3. LiveContainer ターゲットの Sources ビルドフェーズへ追加
    #    該当フェーズの files = ( ... ); を探して先頭に差し込む。
    pattern = re.compile(
        r"(" + re.escape(SOURCES_PHASE_ID)
        + r" /\* Sources \*/ = \{.*?files = \(\n)",
        re.DOTALL,
    )
    match = pattern.search(text)
    if not match:
        fail(
            f"Sources ビルドフェーズ {SOURCES_PHASE_ID} が見つかりません。"
            " 本家の pbxproj が更新されて ID が変わった可能性があります。"
        )

    member_entry = f"\t\t\t\t{BUILD_FILE_ID} /* {FILE_NAME} in Sources */,\n"
    text = pattern.sub(lambda m: m.group(1) + member_entry, text, count=1)

    with open(PBXPROJ, "w", encoding="utf-8") as f:
        f.write(text)

    print(f"追加しました: {FILE_PATH}")
    print(f"  PBXBuildFile      {BUILD_FILE_ID}")
    print(f"  PBXFileReference  {FILE_REF_ID}")
    print(f"  Sources phase     {SOURCES_PHASE_ID}")
    print(f"  pbxproj  {original_length} -> {len(text)} bytes")


if __name__ == "__main__":
    main()
