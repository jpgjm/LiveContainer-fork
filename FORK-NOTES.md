# フォーク版メモ

ベース: **本家 LiveContainer 3.8.6**

本家との差分は次のとおりです。

| 分類 | 内容 |
|---|---|
| **AlarmKit 対応** | `LiveContainer/Info.plist` に `NSAlarmKitUsageDescription` を 1 キー追加 |
| **ヘッドレス起動** | `LaunchAppExtension/LCProbeHeadlessLaunch.swift` (新規) |
| | `LCTabView.checkSoundsBookmark()` — `Library/Sounds` のブックマークを共有 |
| ビルド用の追加 | `.github/workflows/build-ipa.yml`、`.github/build_ipa_only.sh`、`.github/build_sidestore_ipa.sh` |
| ビルド用の変更 | `.github/workflows/build.yml` を手動実行のみに変更 |
| ドキュメント | この `FORK-NOTES.md` |

ヘッドレス起動は、LiveContainer のゲストに**バックグラウンド実行の手段を
与える**ものです。ゲストは App Extension も BGTaskScheduler も使えないため、
これまで手段がありませんでした。

> [!NOTE]
> Quick Share のサービスタイプ `_FC9F5ED42C8A._tcp` は **本家にマージ済み**です
> (Issue #1519)。このフォークで独自に持つ必要はなくなりました。

---

## 0. ヘッドレス起動 (`Probe Headless Launch`)

`LaunchAppExtension/LCProbeHeadlessLaunch.swift` は、**画面を出さずに
ゲストアプリを起動する** App Intent です。ショートカットから使えます。

```
ショートカット (時刻トリガーなど)
  ↓ この Intent。画面は点かない
NSExtension → LiveProcess.appex
  ↓ ゲストが別プロセスで起動
ゲストが処理して自分で exit(0)
```

LiveContainer のゲストは App Extension も BGTaskScheduler も使えないため、
**バックグラウンド実行の手段がありませんでした**。これはその代替になります。

### 使い方

ショートカットに **"Probe Headless Launch"** が出ます。

| パラメータ | 内容 |
|---|---|
| Guest Bundle ID | **`Applications/` 直下のフォルダ名** (例 `com.example.alarmclock.app`) |
| Container Folder Name | 空でよい。`LCAppInfo.plist` の `LCDataUUID` を使う |
| Observe Seconds | **0 のままでよい**。0 なら投げて即座に返る |

> [!IMPORTANT]
> Guest Bundle ID は bundle ID ではなく、**末尾に `.app` が付いたフォルダ名**です。
> `LCSharedUtils.findBundleWithBundleId:` が
> `<LC_HOME_PATH>/Documents/Applications/<引数>` を見るためです。
> LiveContainer のアプリ設定で「バンドルフォルダ」として表示されている値。

結果は `ファイル > LiveContainer > LCProbe.txt` に記録されます。
ゲスト側が何をしたかは、ゲスト自身のログを見てください。

### ホスト側 (LiveContainer) に必要なこと

`LiveProcess.appex` を起こすだけでは動きません。**4 つ揃えて初めて成立します。**
どれが欠けても違う失敗をするので、実測した症状も併記します。

**1. `LC_HOME_PATH` を setenv する**

```swift
let lcHome = docURL.deletingLastPathComponent().path
setenv("LC_HOME_PATH", (lcHome as NSString).utf8String, 1)
```

`LCSharedUtils.findBundleWithBundleId:` は
`getenv("LC_HOME_PATH")/Documents/Applications/<引数>` を見ます。
この環境変数はゲストプロセスでは `LCBootstrap` が設定しますが、
**拡張プロセスでは誰も設定しません**。本家の `LaunchAppExtension.swift` も
ブックマーク解決の直後に同じことをしています。

> 欠けたときの症状: 正しいフォルダ名を渡しても `findBundle = 失敗`

**2. `userInfo` に 4 つのキーを載せる**

`LiveProcess/main.m` が読むキーに合わせます。本家の
`MultitaskSupport/AppSceneViewController.m` と同じ形です。

| キー | 内容 |
|---|---|
| `selected` | ゲストの**フォルダ名** (末尾 `.app`) |
| `selectedContainer` | コンテナ UUID (`LCAppInfo.plist` の `LCDataUUID`) |
| `lcHomePath` | ホストのコンテナ |
| `hostUrlScheme` | **インストール済みかつ未使用**の LC スキーム |

`hostUrlScheme` が最も見落としやすい部分です。`LCBootstrap.m` はこれを
`lcAppUrlScheme` に入れ、`setContainerUsingByLC:` がコンテナロックに書き込みます。

```objc
// LCSharedUtils.m
info[folderName] = @{ @"runningLC": lc, ... };   // lc が nil なら例外
```

`RefreshHandler` (SideStore) がこのキーを渡していないのは、`isSideStore` が
true になって上の分岐を通らないためです。**通常のゲストを起こすときだけ必要**です。

> 欠けたときの症状: `NSInvalidArgumentException` でゲストが即クラッシュ

**3. ブックマークを 4 つ渡す (オプションは `1 << 11`)**

| 対象 | 用途 |
|---|---|
| アプリバンドル | 実行ファイルの読み込み |
| `Data/Application/<uuid>` | ゲストのコンテナ |
| `Tweaks` | tweak の読み込み |
| `Library/Sounds` | **このフォークの追加**。AlarmKit のカスタム音源 |

ゲストのサンドボックスはこれで構成されます。ホストの `Documents` は
**含まれない**ので、そこへの書き込みは `EPERM` になります。

> 欠けたときの症状: `Container not found!` (コンテナ欠落) /
> `NSCocoaErrorDomain code=513` (書き込み先が範囲外)

**4. Documents の外のブックマークは「本体」が作る**

これが一番わかりにくい点です。

**security-scoped bookmark は「自分が持っている権限」しか渡せません。**
`LaunchAppExtension` が持っているのは Documents のブックマークだけなので、
拡張が `Library/Sounds` のブックマークを作っても**権限が伴いません**。
生成自体は成功するので、症状が分かりにくくなります。

本家は Documents について、既にこの形を採っています。

```swift
// LCTabView.checkPrivateContainerBookmark()
guard let bookmark = LCUtils.bookmark(for: LCPath.docPath) else { ... }
LCUtils.appGroupUserDefault.set(bookmark, forKey: "LCLaunchExtensionPrivateDocBookmark")
```

このフォークでは `Library/Sounds` にも同じ形を用意しました
(`checkSoundsBookmark()` → `LCLibrarySoundsBookmark`)。
拡張はそれを読んで転送するだけです。

**`isStale` なら作り直します。** LiveContainer を入れ直すとコンテナ UUID が
変わるので、そのたびに陳腐化します。

> 欠けたときの症状: ブックマークは 4 件渡るのに `sounds-writable=いいえ`

**注意: 本体を一度起動しないと始まりません**

`checkSoundsBookmark()` は `LCTabView` の `onAppear` で走ります。
インストール後に LiveContainer を一度も開いていないと、ブックマークが
存在せず、ゲストは `Library/Sounds` に書けません。

### 追加のパスが要る場合

`Library/Sounds` は AlarmKit 固有です。他のゲストが別の場所を必要とするなら、
同じ形 (本体が作る → App Group に置く → 拡張が転送) を増やしてください。

なお本家は「private app ならコンテナだけに絞る」という意図で
サンドボックスを狭めています
(`// when multitask with private app, we can restrict its sandbox to only its own container`)。
パスを足すのはその意図を一部緩めることになるので、
汎用機構として作り直す際は**ゲストごとに要否を選べる形**にするのが望ましいです。

### ゲスト側に必要なこと

ホスト側が揃っていても、ゲストが次の 3 つを守らないと動きません。

**1. LiveProcess 経由かを判定する**

```swift
let isLiveProcess = ProcessInfo.processInfo.environment["LP_HOME_PATH"] != nil
    || (Bundle.main.executablePath ?? "").contains("LiveProcess.appex")
```

**2. 処理はシーンに依存しない場所に書く**

`.task` や `.onChange(scenePhase)` はシーンが繋がらないと発火しません。
`App.init()` か `UIApplicationDelegate` に置いてください。

> 守らないときの症状: プロセスは起動するのに何も起きない

**3. 処理が終わったら `exit(0)` する。ただし条件付きで**

ヘッドレスで起動したプロセスは誰も止めてくれません。
一方でマルチタスクも同じ `LiveProcess` を使うので、**無条件の `exit(0)` は
表示中のウィンドウを壊します**。

「一定時間待ってもシーンが繋がらなければヘッドレス」と判定するのが安全です。
AlarmClock では 6 秒にしてあります。

```swift
DispatchQueue.global().asyncAfter(deadline: .now() + 6) {
    if sceneConnected { return }   // マルチタスク表示中
    exit(0)
}
```

**書き込み先にも注意**

ゲストのサンドボックスは 4 つのブックマークだけです。
ホストの `Documents` には書けません (`EPERM`)。
記録を残すならゲスト自身の `Documents` を使ってください。

**実装例**

AlarmClock の `Sources/Services/HeadlessRunner.swift` がそのまま雛形になります。
中身を差し替えれば他のアプリでも使えます。
`LaunchTrace.swift` は、画面が出ない実行での唯一の観測手段です。

### 分かっていること

**ゲストのプロセスは `App.init()` まで到達します。**
シーンが接続されないので `.task` や `.onChange(scenePhase)` は発火しませんが、
`UIApplicationMain` は正常に進みます。Swift のコードをそのまま書けます。

当初は「シーンが繋がらないから `App.init()` に到達しない」と考えていましたが、
実測で否定されました (C の `__attribute__((constructor))` と `App.init()` の
両方に痕跡が残った)。

**App Intent には実行時間の制限があります。**
`Observe Seconds = 30` は完走、`60` は
「不明なエラーが発生したため実行できませんでした」で失敗しました。
上限は 30〜60 秒の間です。通常の運用では `0` にして待たないので当たりません。

**ゲストは自分で終了する必要があります。**
ヘッドレスで起動したプロセスは誰も止めてくれません。
ただしマルチタスクも同じ `LiveProcess` を使うため、
無条件の `exit(0)` は表示中のウィンドウを壊します。

### 到達できなかったこと

**AlarmKit の停止ボタンを起点にすることはできません。**

ゲストが宣言した App Intents は installd に登録されないため解決されません。
LiveContainer が宣言した型を同じマングル名で渡す方法も試しました
(`PRODUCT_MODULE_NAME` を合わせる)。`schedule()` は通りましたが、
ボタンを押しても何も起きませんでした。

AlarmKit は**登録元のアプリ**で Intent を紐付けていると思われます。
そのため起点は「停止ボタン」ではなく「ショートカットの時刻トリガー」になります。

---

## 1. `NSAlarmKitUsageDescription`

```xml
<key>NSAlarmKitUsageDescription</key>
<string>The guest app is requesting for this permission.</string>
```

他の `NS*UsageDescription` と同じ扱いです。iOS 26 以降、
`AlarmManager.requestAuthorization()` を呼ぶアプリにはこのキーが必須で、
無いと権限リクエストが失敗します。ゲストの Info.plist は参照されないため、
ホスト側に置く必要があります。

`LiveContainer/Info.plist` にはほぼ全種類の `NS*UsageDescription` が
網羅されており、iOS 26 で追加された AlarmKit だけが漏れている状態でした。

### これだけでは足りないもの

AlarmKit をゲストで使うには、**アプリ側にも対応が要ります**。
LiveContainer 側だけでは解決しません。

| 課題 | 誰が直すか | 内容 |
|---|---|---|
| 権限の用途説明 | **LiveContainer** | 上記のキー (このフォークで対応済み) |
| `Library/Sounds/` のパス | **ゲストアプリ** | 後述 |
| App Intents の解決 | どちらでも不可 | 後述 |

**`Library/Sounds/` のパス**

AlarmKit の `.named(_:)` で指定したカスタム音源は、鳴動時に
**システムデーモンが読みに行きます**。デーモンから見た登録者は
LiveContainer なので、探索先は LiveContainer の実コンテナ配下です。

一方ゲストは `HOME` を差し替えられているため、`Library/Sounds/` に
書いたつもりのファイルはゲストのコンテナ内に置かれ、デーモンからは見えません。

ゲスト側で `LC_HOME_PATH` 環境変数 (LiveContainer が退避しているホストの
本来の HOME) を見て、書き込み先を切り替える必要があります。

```swift
if let lcHome = ProcessInfo.processInfo.environment["LC_HOME_PATH"] {
    // LiveContainer 内 → ホストの実コンテナに書く
    return URL(fileURLWithPath: lcHome).appendingPathComponent("Library/Sounds")
}
```

この環境変数は `LiveContainer/LCBootstrap.m` が `HOME` を差し替える前に
`setenv("LC_HOME_PATH", getenv("HOME"), 0)` で退避しているものです。
**ゲストアプリが「LiveContainer 内で動いているか」を判定する手段としても使えます。**

**App Intents の解決** (実測済み)

`stopIntent` / `secondaryIntent` に渡す `LiveActivityIntent` は、
インストール時に installd へ登録された `Metadata.appintents` から解決されます。
LiveContainer 内のゲストアプリは登録簿に存在しないため、
**ゲストが宣言した Intent 型は解決できません。**

実機で確認した結果:

| 確認したこと | 結果 |
|---|---|
| Intent 付きで `schedule()` できるか | **できる** (登録時に解決可能性は検証されない) |
| ボタン押下で `perform()` が走るか | **走らない** (ログが一切残らない) |
| `openAppWhenRun = true` でアプリが開くか | **開かない** |
| スヌーズ (`.custom`) を押したとき | **アラートが鳴り止まない** |

最後の 1 つが決定的です。`.custom` のスヌーズは Intent 内で `stop()` を
呼ばないと鳴り止まない設計なので、鳴り続ける = Intent が走っていない、
と確定できます。なお **停止ボタンでアラートが止まるのは AlarmKit 標準の挙動**
であって、Intent が動いた証拠にはなりません。

Info.plist の追記では解決しません。ゲスト側で
`stopIntent` / `secondaryIntent` を `nil` にして、AlarmKit ネイティブの
`.countdown` スヌーズにフォールバックしてください。
**LiveContainer 内で `.custom` を使うとアラームを止められなくなる**ため、
これは機能制限ではなく必須の安全策です。

> 将来的には、SideStore と同じ手法 (ゲストの `Metadata.appintents` を
> ホストのバンドルに焼き込む) で解決できる可能性があります。
> ただし Intent の実装を常時ロードされる framework 側に置く必要があり、
> LiveContainer とゲスト双方への大きめの実装が要るため、
> このフォークには含めていません。

**BGTaskScheduler について**

`BGTaskSchedulerPermittedIdentifiers` はゲストごとに固有の識別子になるため、
このフォークでは**追加していません** (本家に出せる性質のものでもありません)。
ゲスト側で `LC_HOME_PATH` を見て `BGTaskScheduler.register()` を
スキップしてください。登録しても `notPermitted` で失敗します。

---

## 2. IPA のビルド

### 成果物は 2 つ

| 成果物 | 中身 |
|---|---|
| `LiveContainer.ipa` | 素の LiveContainer |
| `LiveContainer+SideStore.ipa` | SideStore を**内蔵ゲストアプリ**として同梱 |

多くの場合は同梱版を使うことになります。無料 Apple ID はインストール枠が
3 つしかないため、LiveContainer と SideStore で 2 枠使うのは割に合いません。

> [!NOTE]
> 同梱版でも App ID は **2 つ**消費します
> (`com.kdt.livecontainer` と `com.kdt.livecontainer.LiveWidget`)。
> 節約できるのはインストール枠のほうです。

### SideStore はホストではなくゲスト

同梱版の SideStore は、LiveContainer と並ぶホストアプリではありません。
実行ファイルを `dylibify` で dylib 化し
(`MH_EXECUTE` → `MH_DYLIB`、`LCPatchExecSlice()` と同じ変換)、
`Frameworks/SideStoreApp.framework` として置いた**ゲストアプリ**です。
専用の `LCAppInfo.plist` を持ち、固定の `LCDataUUID` で起動します。

ただし通常のゲストにはできないことができます。**宣言をホストの
バンドルに焼き込んでいる**ためです。

| 焼き込むもの | 効果 |
|---|---|
| `CFBundleURLTypes` に `sidestore://` | URL スキームが実際に登録される |
| `Metadata.appintents` をホスト直下へ | App Intents が実際に解決される |
| `AltWidgetExtension.appex` → `PlugIns/LiveWidgetExtension.appex` | ウィジェットが動く |
| `INIntentsSupported` / `NSUserActivityTypes` | ショートカット連携 |
| `Settings.bundle` に「Open SideStore」 | 設定アプリから起動 |

App Intents の移植では Swift のマングル名を書き換えています
(実装が `SideStoreSupport.framework` 側にあるため)。

```
9SideStore20RefreshAllAppsIntentV
→ 16SideStoreSupport20RefreshAllAppsIntentV
```

先頭の数字はモジュール名の文字数です。

### 本家スクリプトからの変更点

`.github/build_github.sh` は本家のリリース処理と一体になっているため、
フォークでは 2 つに分けています。**本家のスクリプト自体は変更していません。**

| スクリプト | 役割 |
|---|---|
| `build_ipa_only.sh` | 素の IPA を作る。`Payload/` は残す |
| `build_sidestore_ipa.sh` | その `Payload/` から同梱版を作る |

素の IPA を先に作ってアップロードしてから同梱版に進むので、
外部ダウンロード (dylibify / SideStore nightly) が失敗しても
素の IPA は手に入ります。

本家 `build_github.sh` との差分:

- **`wget` ではなく `curl -fsSL`** — ランナーに `wget` が無い場合があり、
  `-f` で HTTP エラーも検出できる
- **`SideStoreSupport.framework` を消さずに退避** — 同梱版が必要とするため
- **Settings.bundle への追記を末尾追加に変更** — 本家は
  `:PreferenceSpecifiers:3` に決め打ちしているが、実際の要素数は 2 なので
  そのままでは PlistBuddy が失敗する
- **検証を追加** — sed の置換成否、dylib 化 (`MH_DYLIB`)、`_CodeSignature` の数、
  4 つの拡張の存在、`NSAlarmKitUsageDescription` が同梱版にも残っているか

**`_CodeSignature` は本家と同じく削除しません。** 本家の
`find payloadlc/Payload ...` は存在しないパスを参照していて実質何もしませんが、
それが正しい状態です (公式 IPA にも 11 個残っています)。

### 実行

Actions タブ → "Build IPA (fork)" → Run workflow。

`build_sidestore` を off にすると素の IPA だけを作ります。
外部ダウンロードが不安定なときや、同梱版が不要なときに使ってください。

`compare_with_official` を on にすると、出来上がった同梱版を
公式 nightly の同梱版と構造比較します (調査用)。

### `Refresh All Apps` が失敗するときの調べ方

自前ビルドの同梱版でのみ、ショートカットの `Refresh All Apps` が
`Swift.CancellationError エラー1` で失敗する事例がありました。

**まず切り分けてください。**

1. **公式 nightly の +SideStore.ipa** を入れて `Refresh All Apps` を試す
   - `https://github.com/LiveContainer/LiveContainer/releases/download/nightly/LiveContainer+SideStore.ipa`
   - これは **3.8.6** です (タグ付きリリースには 3.8.0 以降 +SideStore.ipa が無いため、
     3.8.6 を公式ビルドで試すにはこれを使います)
2. 公式でも失敗する → **本家 3.8.6 の問題**。フォークの責任ではない
3. 公式は成功する → **こちらのビルドの問題**。以下を確認

**3.8.0 との比較は成立しません。** 3.8.0 と 3.8.6 では
この機構そのものが作り替えられています。

| | 3.8.0 | 3.8.6 |
|---|---|---|
| Framework 名 | `SideStore.framework` | `SideStoreSupport.framework` |
| `Metadata.appintents` のマングル名 | `9SideStore20RefreshAllAppsIntentV` (書き換えなし) | `16SideStoreSupport20RefreshAllAppsIntentV` (sed で書き換え) |

3.8.0 は Framework 名が `SideStore` だったため書き換え自体が不要でした。
3.8.6 で改名され、`build_github.sh` に sed が入っています。

**過去にこのフォークが埋め込んだ不具合 (v7 で修正済み)**

`build_sidestore_ipa.sh` が `_CodeSignature` を削除していました。

```sh
# v5 / v6 — 誤り
find Payload -type d -name "_CodeSignature" -exec rm -rf {} +
```

本家の該当行は `payloadlc/Payload` という**存在しないパス**を参照しており、
実質的に何もしていません。これを「本家のバグ」と判断して `Payload` に
直したのが誤りでした。公式の +SideStore.ipa を展開して確認したところ、
`_CodeSignature` は **11 個すべて残ったまま配布されています**。

削除すると、SideStore で再署名したときに拡張の登録が壊れ、
`Refresh All Apps` が `LiveProcess.appex` を `NSExtension` として
起こせなくなる可能性があります。v7 では本家と同じく `.zsign_cache` だけを消します。

**v7 で追加した検証**

- sed の置換前後を検査する (SideStore nightly のマングル名が変わったら
  黙って素通りするのを防ぐ)
- `_CodeSignature` の数を数える (0 個ならエラー)
- 4 つの拡張 (`LiveProcess` / `ShareExtension` / `LaunchAppExtension` /
  `LiveWidgetExtension`) が揃っているか確認する

**それでも失敗する場合**

`compare_with_official` を on にしてビルドし、公式 nightly との
ファイル構成差分を確認してください。

インストール時の注意も効きます。SideStore で入れる際は
**「Keep App Extensions (Use Main Profile)」を選んでください。**
拡張を削ぐ設定だと `LiveProcess.appex` が登録されず、
`RefreshHandler` が `NSExtension` を作れません
(`SideStoreSupport/SideStore.swift` にその旨のエラーメッセージがあります)。

---

## 3. 動作確認

インストールは毎回 **アンインストール → 端末再起動 → 再インストール** で行います。

1. ゲストアプリ (AlarmClock など) を起動する
2. AlarmKit の権限ダイアログが出て、許可できること
   - ここで何も出ずに拒否される場合、`NSAlarmKitUsageDescription` が
     ビルドに入っていません
3. アラームを登録し、実際に鳴ること
4. カスタム音源を指定した場合、その音が鳴ること
   - システム標準音になる場合、ゲスト側の `Library/Sounds` パス対応が
     入っていません

権限ダイアログもアラート画面も **「LiveContainer」名義**で表示されます。
ゲストアプリの名前やアイコンは出ません。

また AlarmKit の登録枠は**全ゲストアプリで共有**されます。
取り残された登録が溜まると上限に達して新規登録が失敗するので、
ゲスト側に登録一覧の確認手段を持たせておくことを勧めます。

---

## 4. 上流に PR を出す場合

`LiveContainer/Info.plist` の 1 キーだけを出してください。
ワークフローとスクリプトの変更はフォーク固有の都合なので含めません。

論点はこう組み立てると通りやすいはずです。

- `LiveContainer/Info.plist` には **ほぼ全種類の `NS*UsageDescription` が
  網羅されている**。AlarmKit (iOS 26 で追加) だけが漏れている
- 説明文は既存のものと同一で、**新しい entitlement も権限も要求しない**
- これが無いとゲストは `requestAuthorization()` すら呼べない

「iOS 26 で増えた用途説明キーの取りこぼし」という位置づけが素直です。

ただし前述のとおり、これだけで AlarmKit を使うゲストが完全に動くわけでは
ありません。PR の説明では**「権限リクエストが通るようになる」までが範囲**だと
明示しておいたほうが、後から混乱が起きません。

Bonjour のときと同じく、**特定アプリ向けではなく iOS の標準キーの
取りこぼし**という論点なので、受け入れられる見込みはあると思います。

---

## 5. 上流への追随

このフォークの差分は Info.plist の 1 キーだけなので、**本家の最新版に
キーを 1 つ足し直すだけでリベースできます。**

3.8.5 ベースで運用していたときは、本家が

- `Info.plist` を `Resources/` から `LiveContainer/` へ移動
- `SideStoreSupport/SideStoreHooks.m` を書き直し
  (`hook_storeAppBundleIdentifier` の追加、バージョン表示の実装変更)

を入れたため、1 バージョンで無視できない差が生まれました。
**本家のリリースが出たら早めにリベースし直してください。**

リベース手順:

1. 本家の最新版を取得する
2. `LiveContainer/Info.plist` に `NSAlarmKitUsageDescription` を追加する
3. `.github/workflows/build-ipa.yml`、`.github/build_ipa_only.sh`、
   `.github/build_sidestore_ipa.sh`、この `FORK-NOTES.md` をコピーする
4. `.github/workflows/build.yml` の `on:` を手動実行のみに絞る
5. Info.plist の場所が変わっていたら、`build-ipa.yml` の `PLIST=` を直す

---

## 6. 代替案として成立しないもの

Bonjour を避けて生の mDNS を UDP マルチキャストで自前実装する方法は
成立しません。`com.apple.developer.networking.multicast` entitlement が必要ですが、
これは Apple の個別審査が要り、無料 Apple ID では取得できません。
**LiveContainer 自身もこの entitlement を持っていません**
(`entitlements.xml` / `entitlements.catalyst.xml` / 各 `*.entitlements` を確認済み)。
