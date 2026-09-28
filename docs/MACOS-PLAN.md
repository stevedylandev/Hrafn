# Hrafn for macOS — Plan

*September 2026. Companion to [PLAN.md](../PLAN.md); tracks alongside [PHASE-STATUS](PHASE-STATUS.md).*

## 0. Decisions

| Decision | Choice | Consequence |
| --- | --- | --- |
| Approach | **Native SwiftUI on macOS** (multiplatform target), not Mac Catalyst | Real Mac idioms (menus, windows, Settings scene, sidebar). Every UIKit call in the app target needs a macOS path. Catalyst would compile sooner but feels like an iPad app and keeps UIKit baggage. |
| Target layout | **One multiplatform app target** (`SUPPORTED_PLATFORMS = iphoneos iphonesimulator macosx`, `SDKROOT = auto`) | Same bundle ID (`com.stevedylandev.Hrafn`) on both platforms; keeps a universal purchase open if the App Store ever happens. Platform differences live in `#if os(macOS)` or small platform files, not a forked codebase. |
| Floor | **macOS 15 Sequoia** | Plain `group.` App Group identifiers work (no team-prefixed fallback). Packages keep `.macOS(.v14)`; only the app target is raised. |
| Packages | Unchanged | XMPPKit, OMEMOKit and HrafnKit already build and test on macOS in CI (`swift test` on `macos-15`). No UIKit in any package source. |
| Connection model | **Stay connected while the app runs; no push on Mac** | macOS does not suspend apps. The iOS background grace/logout (`enterBackground`) is iOS-only; on Mac the session lives until quit. No APNs registration, no XEP-0357 on Mac, no NSE. Notifications come from the live session. |
| Last window closed | **App keeps running** | `applicationShouldTerminateAfterLastWindowClosed` → `false`; a menu-bar extra and login item keep Hrafn reachable and connected. |
| Distribution | **Direct download** (Developer ID, notarised) | No Mac App Store review; Sparkle for updates; DMG from the website (`web/`). App Store stays possible later since the app is sandboxed anyway. |
| v1 Mac scope | Parity with iOS text, rooms, media, OMEMO, notifications | Share extension is a later phase. QR *scanning* by camera is dropped on Mac (QR from image file instead). |

---

## 1. What is iOS-only today

Audit of the app target (`Hrafn/`, `HrafnShare/`, `HrafnNotificationService/`). The packages are clean.

| Area | Where | macOS replacement |
| --- | --- | --- |
| App delegate | `HrafnApp.swift` (`@UIApplicationDelegateAdaptor`), `App/AppDelegate.swift` (`UIApplicationDelegate`, `registerForRemoteNotifications`) | `@NSApplicationDelegateAdaptor` + `NSApplicationDelegate`. Ask for notification permission only; skip `registerForRemoteNotifications` (no push on Mac). `UNUserNotificationCenterDelegate` code is shared as-is. |
| Background assertion | `AppDelegate.swift` `BackgroundAssertion` (`beginBackgroundTask`) | No-op on macOS, or `ProcessInfo.beginActivity(options: .userInitiated)` for notification-action work. |
| Lifecycle | `HrafnApp.swift` `scenePhase` → `enterBackground()`; `AppModel.swift:207` `UIApplication.shared.applicationState` | On Mac, `scenePhase` goes `.background` when all windows close — **do not log out**. Map to XEP-0352 CSI inactive only (`NSApplication.didResignActive` / `didBecomeActive`). Guard `enterBackground()` logout with `#if os(iOS)`. |
| Colours | `App/Themes.swift:129`, `App/Appearance.swift:138,180` (`UIColor`, `secondarySystemBackground`) | `NSColor(self).usingColorSpace(.sRGB)?.getRed…` (NSColor throws on non-RGB spaces without conversion); `NSColor.controlBackgroundColor` / `.underPageBackgroundColor`. Wrap in a `PlatformColor` helper. |
| Images | `Views/MediaViews.swift`, `Views/Components.swift`, `Views/QRCode.swift` (`UIImage`, `preparingThumbnail`) | `typealias PlatformImage = UIImage / NSImage` + `Image(platformImage:)` extension. Thumbnails via the existing `CGImageSource` downsample path, which is already platform-neutral — make it the only path. |
| Zoom viewer | `MediaViews.swift:250` `ZoomableImage: UIViewRepresentable` (UIScrollView) | `NSViewRepresentable` over `NSScrollView` with `allowsMagnification`, or pure SwiftUI `MagnifyGesture` + `ScrollView`. |
| Full-screen media | `MediaViews.swift:81` `.fullScreenCover` | Open media in its own window (`openWindow(value: MediaRoute)`), or `.sheet` sized to content. Quick Look (`QLPreviewPanel`) is a good fit for files. |
| Audio | `MediaViews.swift:312,417,467` `AVAudioSession` | Not on macOS; drop the session calls. `AVAudioRecorder`/`AVAudioPlayer` work. Mic permission via `AVCaptureDevice.requestAccess(for: .audio)`. |
| Pasteboard | `ChatView.swift:80,626,636,699`, `ThemeViews.swift:42,107,189,192` (`UIPasteboard`) | Small `Pasteboard` helper (`string`, `url`, `image`) over `NSPasteboard.general`. |
| QR scanning | `QRCode.swift:70` `DataScannerViewController` (VisionKit, iOS only) | Hide "Scan" on Mac. Add "Import QR from image…" (`fileImporter` + `CIDetector(ofType: CIDetectorTypeQRCode)` or Vision `VNDetectBarcodesRequest`), plus paste of `xmpp:` links. QR *generation* (`CIFilter.qrCodeGenerator`) works as-is. |
| Nav bar modifiers | ~20 × `.navigationBarTitleDisplayMode(.inline)`; `ChatView.swift:221` `.topBarTrailing` | Unavailable on macOS. Add a `View.inlineTitle()` extension that is a no-op on Mac; use `.primaryAction` placement. |
| Text input modifiers | `.keyboardType`, `.textInputAutocapitalization` in AccountSetup, Settings, Rooms, ContactList, ConversationList, StreamProbe | Unavailable on macOS. Replace with a `View.addressField()` / `.numberField()` extension that applies them on iOS only and `.autocorrectionDisabled()` everywhere. |
| List style | `SettingsView.swift:28` `.insetGrouped` | `.formStyle(.grouped)` on Mac; Settings moves to a `Settings` scene anyway. |
| Photos | `SettingsView.swift`, `ChatView.swift` (`PhotosPicker`) | `PhotosPicker` exists on macOS 13+, keep it. Add `.fileImporter` (Mac users attach from Finder far more than Photos), drag-and-drop and paste. |
| Share extension | `HrafnShare/ShareViewController.swift` (`UIViewController`, `UIHostingController`) | Phase M5: `NSViewController` + `NSHostingController`; `ShareModel`/`ShareView` shared. |
| Keychain | `HrafnKit/.../CredentialStore.swift` | Set `kSecUseDataProtectionKeychain: true` on macOS so access groups and `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` behave as on iOS (the legacy file keychain ignores both). |
| Entitlements | `Config/Hrafn.entitlements` | New `Config/Hrafn-macOS.entitlements` (see §2). |
| Info.plist keys | `INFOPLIST_KEY_UI*` build settings | Keep under `[sdk=iphoneos*]`; add `LSApplicationCategoryType = public.app-category.social-networking`, `NSMicrophoneUsageDescription`. Camera usage string not needed. |

---

## 2. Signing, sandbox and distribution

* **Developer ID** signing with a **Developer ID provisioning profile** — needed because
  the App Group and keychain access group are restricted entitlements.
* **Hardened runtime** on (required for notarisation). No exceptions expected; the
  microphone needs `com.apple.security.device.audio-input`.
* **App Sandbox** on anyway: cheap, limits damage from a parser bug, and keeps the Mac
  App Store open as a later option.
  `com.apple.security.app-sandbox`, `network.client`, `files.user-selected.read-write`,
  `device.audio-input`, `com.apple.security.personal-information.photos-library` (only if PhotosPicker needs it).
* **No push entitlement** on Mac.
* **App Group:** `group.dev.stevedylandev.hrafn`, as on iOS — fine on macOS 15 with the
  profile. `SharedContainer` already falls back to Application Support when missing.
* **Keychain access group:** keep `$(AppIdentifierPrefix)dev.stevedylandev.hrafn.shared`;
  requires the data-protection keychain (§1).
* **Notarisation:** `xcodebuild archive` → `-exportArchive` (method `developer-id`) →
  `xcrun notarytool submit --wait` → `xcrun stapler staple` on the app and the DMG.
  Run it in a tag-triggered CI release job with the Developer ID certificate and a
  notary API key as secrets.
* **Updates:** [Sparkle](https://sparkle-project.org) 2 (MIT — add to the allowlist in
  `scripts/license-audit.sh`), EdDSA-signed appcast hosted with the website. Sparkle's
  sandboxed installer needs its XPC services and the
  `com.apple.security.temporary-exception.mach-lookup.global-name` entries from its docs.
  Mac-only dependency: link it to the macOS destination only.
* **Download:** DMG (`create-dmg` or `hdiutil`) served from the website, with the
  appcast and release notes.
* **Account lock files** (`AccountLock`) — confirm `flock` semantics inside the sandbox
  container; unit tests already run on macOS so this is likely fine.

---

## 3. Mac UI

Keep views shared; change the shell.

* **Root:** replace the `TabView` in `ContentView` with a three-column
  `NavigationSplitView` — sidebar (Chats, Contacts, Rooms, account switcher) → list →
  chat. `ConversationListView` and `ContactListView` already use `NavigationSplitView`
  internally for iPad; lift that up rather than nesting.
* **Settings scene:** `Settings { SettingsView() }` opened with ⌘, instead of a tab;
  use a `TabView` of panes (Accounts, Appearance, Notifications, Encryption, Advanced).
* **Windows:** `WindowGroup(for: ChatRoute.self)` so a chat can pop out into its own
  window (double-click in the list). Media viewer as its own `WindowGroup(for:)`.
* **Commands:** `CommandMenu`/`CommandGroup` — New Chat ⌘N, Join Room ⇧⌘N, Add Contact,
  Find ⌘F (`.searchable` focus), Next/Previous Conversation ⌃Tab/⌃⇧Tab or ⌘]/⌘[,
  Mark as Read, Show XML Console (DEBUG). `@FocusedValue` to target the active chat.
* **Composer:** Return sends, ⇧/⌥-Return inserts newline (`onKeyPress`); drag files
  onto the chat (`dropDestination(for: URL.self)`); ⌘V pastes images as attachments.
* **Context menus** replace swipe actions (keep both; swipe also works with trackpad).
* **Dock badge:** `NSApp.dockTile.badgeLabel` from `database.unreadTotal()`, same
  source as the iOS badge.
* **Density:** sizes and paddings tuned for pointer (`.controlSize`, smaller avatars,
  hover states on messages for reply/react).
* **Menu-bar extra** (M4): `MenuBarExtra` with unread count and recent chats; lets
  Hrafn keep running with no windows open.
* **Login item** (M4): `SMAppService.mainApp.register()` toggle in Settings.

---

## 4. Notifications on macOS

No push on Mac. Hrafn keeps running (login item, menu-bar extra, stays alive with no
windows), so the live session is the only source of notifications.

* `SystemNotifier` posts local notifications from the live session — the same path iOS
  uses in the foreground, minus the "chat list is the notification" suppression.
  `willPresent` returns `[.banner, .sound]` unless the chat is open in the key window.
* Reply / Mark Read actions (`MessageNotification.categories`) work unchanged.
  `handleInBackground` skips the resume/suspend dance on Mac (never suspended).
* Never register XEP-0357 push from the Mac resource, so the server doesn't push to a
  device that never wakes. The iPhone's registration is unaffected; with carbons and
  read markers, both devices stay in step.
* Sleep/wake: reconnect on `NSWorkspace.didWakeNotification` (the `PathMonitor` may not
  see a change), and rely on stream resumption (XEP-0198) for short sleeps.

---

## 5. Phases

Each phase ends with a green build on both platforms.

### M0 — Target and build · ~2 days
* Add macOS to the Hrafn target's supported destinations; per-SDK build settings
  for Info.plist keys, entitlements file, deployment target.
* Exclude `HrafnShare` / `HrafnNotificationService` from the Mac build for now.
* Stub every item in §1 behind `#if os(iOS)` just enough to compile; ship the
  platform shims as `Hrafn/Platform/` (`PlatformImage`, `PlatformColor`,
  `Pasteboard`, `View+Platform` for the no-op modifiers).
* CI: add `xcodebuild build -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO`
  to the `app` job; run `sync-strings.sh --check` once.
* **Exit:** app launches on Mac, onboarding screen shows.

### M1 — Core parity · ~1 week
* `NSApplicationDelegateAdaptor`, lifecycle rework (§1 Lifecycle): CSI on
  resign/become active, no suspend/logout.
* Data-protection keychain, sandbox entitlements, App Group decision (§2).
* Log in, roster, 1:1 chats, rooms, MAM catch-up, OMEMO — all via the unchanged
  packages. Verify against the Docker Prosody/ejabberd servers.
* Colours and themes (`Themes`, `Appearance`, Base16 import via pasteboard).
* **Exit:** two-device test (iPhone + Mac, same account) with carbons, OMEMO to both
  devices, read markers synced.

### M2 — Mac shell · ~1 week
* Three-column `NavigationSplitView`, `Settings` scene, commands/keyboard shortcuts,
  composer key handling, context menus, hover actions, dock badge.
* Pop-out chat windows (`WindowGroup(for: ChatRoute.self)`); `onOpenURL` for `xmpp:`
  links routes to the frontmost window.
* **Exit:** every iOS screen reachable on Mac by mouse and keyboard; no iOS-looking
  nav bars.

### M3 — Media · ~1 week
* `PlatformImage` everywhere; media viewer window with zoom; Quick Look for files.
* Attach via `fileImporter`, drag-and-drop, paste, PhotosPicker.
* Voice messages: recorder/player without `AVAudioSession`; mic permission prompt.
* Save attachment → `NSSavePanel` / "Show in Finder".
* **Exit:** send and receive image, video, file, voice message Mac ↔ iPhone, including
  OMEMO-encrypted (`aesgcm://`) files.

### M4 — Always running + notifications · ~4 days
* `applicationShouldTerminateAfterLastWindowClosed` → `false`; reopen the main window
  from the Dock (`applicationShouldHandleReopen`) and the menu-bar extra.
* `MenuBarExtra` with unread count and recent chats; login item via
  `SMAppService.mainApp` (toggle in Settings, on by default after first account).
* Local notifications from the live session with Reply / Mark Read actions (§4).
* Reconnect on wake from sleep.
* **Exit:** close every window, lid closed and reopened — a new message still arrives
  as a notification and an inline reply delivers.

### M5 — Share extension · ~3 days
* macOS Share extension target (`NSExtensionPointIdentifier = com.apple.share-services`),
  `NSViewController` hosting the existing `ShareView`; `ShareDelivery` unchanged.
* **Exit:** share a file from Finder / a link from Safari into a conversation.

### M6 — Direct-download release · ~1 week
* Developer ID certificate and provisioning profile; notarisation pipeline (§2) as a
  tag-triggered CI job producing a stapled DMG.
* Sparkle 2: appcast, EdDSA key (kept out of the repo), "Check for Updates…" menu item,
  automatic checks on by default.
* Download page and appcast on the website (`web/`); release notes per version.
* Security pass (update [SECURITY-REVIEW](SECURITY-REVIEW.md)): sandbox, hardened
  runtime, keychain class, file permissions in the container, XML console redaction,
  update-feed signing.
* UI tests: macOS variants of `HrafnUITests` for onboarding, send, and room join.
* **Exit:** fresh Mac downloads the DMG, opens without Gatekeeper warnings, and
  updates itself to the next build.

---

## 6. Testing

* Packages: already run on macOS in CI — no change.
* App: add a macOS build job to CI (M0), and a macOS UI test job once M2 lands.
* Manual matrix per phase: Mac ↔ iPhone same account, Mac ↔ other client
  (Conversations/Gajim), against both Docker servers and one public server.
* Watch for: `scenePhase` differences, multiple windows showing the same chat (read
  markers sent twice — dedupe in `AccountManager`), keychain prompts on first run
  (means the legacy keychain is being hit).

## 7. Decisions log

| Question | Answer |
| --- | --- |
| Mac floor | macOS 15 — plain `group.` App Group. |
| Push on Mac | No — the app stays running (login item + menu-bar extra). |
| Distribution | Direct download: Developer ID, notarised DMG, Sparkle updates. |
| Close last window | Keep running in the menu bar. |
