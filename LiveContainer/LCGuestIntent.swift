//
//  LCGuestIntent.swift
//  LiveContainer
//
//  A generic proxy intent for guest apps.
//
//  ── The problem ─────────────────────────────────────────────────
//
//  A guest app's App Intents are never registered with `installd`. Only the
//  metadata inside `LiveContainer.app` is indexed, so the guest's own bundle is
//  never scanned.
//
//  As a result, any system API that requires a **registered**
//  `LiveActivityIntent` silently does nothing for guests:
//
//    - AlarmKit  : `AlarmManager.AlarmConfiguration`'s stopIntent / secondaryIntent
//    - WidgetKit : `Button(intent:)` / `Toggle(intent:)`
//    - Controls  : ControlWidget actions
//
//  AlarmKit also carries a real hazard. `secondaryButtonBehavior = .custom`
//  requires the intent itself to call `stop()`, so an unresolved intent means
//  **an alarm that cannot be stopped**.
//
//  ── There is no other route (measured on iPadOS 26, iPad 9th gen) ──
//
//    | Approach | Result |
//    |---|---|
//    | LiveActivityIntent declared by the guest | not resolved |
//    | LiveActivityIntent declared in an App Intents extension | not resolved |
//    | Spawn LiveProcess.appex from a backgrounded app process | fails |
//    | Same, from a BGContinuedProcessingTask handler | **fails** |
//
//  The fourth is decisive. Even with a system-granted background execution
//  assertion, `beginExtensionRequestWithInputItems:` completes with a nil UUID
//  and neither the cancellation nor the interruption block fires. The same call
//  works from the foreground (multitasking), so the condition is "is the app in
//  the foreground", not "does it hold an assertion".
//
//  A guest process cannot be started from the background. That leaves running
//  the guest's code inside LiveContainer's own process.
//
//  ── What this does ──────────────────────────────────────────────
//
//  Looks up a symbol with `RTLD_DEFAULT` and calls it. That is all.
//
//  **It loads nothing.** The dylib is already in the process because of the
//  existing tweak mechanism (`LCBootstrap.m`):
//
//      if ([lcUserDefaults boolForKey:@"LCLoadTweaksToSelf"]) {
//          setenv("LC_GLOBAL_TWEAKS_FOLDER", tweakFolder.UTF8String, 1);
//          dlopen("@executable_path/Frameworks/TweakLoader.dylib", RTLD_LAZY);
//      }
//
//  That runs immediately before `LiveContainerSwiftUIMain()`, so it applies when
//  the app is launched into the background for the intent as well. No new
//  injection path is introduced; this only opens an exit for something already
//  loaded.
//
//  `action` and `payload` are passed through untouched.
//
//  ── What a guest has to do ──────────────────────────────────────
//
//  1. Declare a structurally identical stub and hand it to the system API.
//     Matching `persistentIdentifier` is sufficient; the Swift mangled names do
//     not need to match (verified with host module `LiveContainer` and guest
//     module `AlarmClock`).
//  2. Ship a dylib exporting an entry point:
//
//         @_cdecl("MyAppGuestPerform")
//         public func MyAppGuestPerform(
//             _ action: UnsafePointer<CChar>?,
//             _ payload: UnsafePointer<CChar>?
//         ) -> Int32
//
//     with `DEAD_CODE_STRIPPING = NO`, since nothing in the dylib references it.
//  3. The user imports it into the global Tweaks folder, signs it from the
//     Tweaks tab, and enables "Load Tweaks to LiveContainer Itself".
//
//  Symbol names should be app-specific: `RTLD_DEFAULT` resolves first-match, so
//  two apps exporting the same name would collide.
//
//  ── Risk ────────────────────────────────────────────────────────
//
//  `LiveProcess/main.m`'s `customPayloadDylib` / `customPayloadEntry` does the
//  same thing — dlopen a dylib named by the caller, dlsym a function named by
//  the caller, call it — but in the LiveProcess **child** process, where a crash
//  does not take LiveContainer down. This runs in the **host** process, so the
//  risk is of a different kind. Three things limit it:
//
//    - LiveContainer loads nothing; whether a tweak is injected is the user's
//      existing opt-in
//    - only symbols already present in the process are called
//    - if the symbol is absent, perform() returns quietly
//

import AppIntents
import Foundation

@available(iOS 17.0, *)
struct LCGuestIntent: LiveActivityIntent {

    static var title: LocalizedStringResource = "LiveContainer Guest Action"

    static var description = IntentDescription(
        "Calls a function exported by a tweak loaded into LiveContainer, on behalf of a guest app."
    )

    /// Not meant to be run by hand; keep it out of the Shortcuts library.
    static var isDiscoverable: Bool = false

    /// Guests use this from lock screen surfaces (alarms, Live Activities),
    /// where bringing LiveContainer to the front would be wrong.
    static var openAppWhenRun: Bool = false

    /// The only contact point with the guest's stub.
    ///
    /// Matching this is enough for the system to resolve the host's
    /// implementation; the Swift mangled names do not have to match.
    static var persistentIdentifier: String { "com.kdt.livecontainer.guestIntent" }

    // MARK: - Parameters
    //
    // A guest's stub must match these exactly: names, types and declaration
    // order.

    /// The C symbol to call, exported by a tweak loaded into this process.
    ///
    /// Expected signature:
    ///
    ///     int32_t handler(const char *action, const char *payload);
    ///
    /// `RTLD_DEFAULT` resolves first-match, so this should be app-specific.
    @Parameter(title: "Handler Symbol")
    var handler: String

    /// Passed through to the guest. LiveContainer does not interpret it.
    @Parameter(title: "Action")
    var action: String

    /// Passed through to the guest. LiveContainer does not interpret it.
    @Parameter(title: "Payload")
    var payload: String

    init() {
        self.handler = ""
        self.action = ""
        self.payload = ""
    }

    init(handler: String, action: String = "", payload: String = "") {
        self.handler = handler
        self.action = action
        self.payload = payload
    }

    // MARK: - Perform

    func perform() async throws -> some IntentResult {
        guard !handler.isEmpty else { return .result() }

        // RTLD_DEFAULT. Looks up a symbol that is already loaded; loads nothing.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), handler) else {
            NSLog("[LCGuestIntent] %@ not found. "
                + "Is the tweak signed and is \"Load Tweaks to LiveContainer Itself\" on?",
                  handler)
            return .result()
        }

        typealias GuestEntry =
            @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
        let call = unsafeBitCast(symbol, to: GuestEntry.self)

        let result = action.withCString { actionPtr in
            payload.withCString { payloadPtr in
                call(actionPtr, payloadPtr)
            }
        }
        NSLog("[LCGuestIntent] %@ result=%d", handler, result)

        return .result()
    }
}
