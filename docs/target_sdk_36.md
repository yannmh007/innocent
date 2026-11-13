# targetSdk 36 (Android 16): raised 13 Nov 2026

**Raised** on 13 Nov, the owner's choice (`targetSdk = 36` in
`android/app/build.gradle.kts`; it was Flutter 3.32.8's default, 35). The
app is not on Google Play (its own updater, `app_releases`), so no store
date forced it; Android does, a step at a time. Below: what changes for an
app that targets 36, what Innocent does about each, and what is left.
Sources: Android's own pages, read on 13 Nov —
[behavior changes 16](https://developer.android.com/about/versions/16/behavior-changes-16),
[17](https://developer.android.com/about/versions/17/behavior-changes-17),
[compat changes 16](https://developer.android.com/about/versions/16/reference/compat-framework-changes),
[testing them](https://developer.android.com/guide/app-compatibility/test-debug),
[local network](https://developer.android.com/privacy-and-security/local-network-permission),
[predictive back](https://developer.android.com/guide/navigation/custom-back/predictive-back-gesture).

## What changes at 36, and where Innocent stands

| Change (apps targeting 36, on Android 16) | Innocent | State |
|---|---|---|
| **Orientation, resizability and aspect-ratio requests ignored** where the screen's smallest width is 600 dp or more (`setRequestedOrientation`, so `SystemChrome.setPreferredOrientations`; `screenOrientation`; `resizeableActivity`; min/max aspect). Not below 600 dp, not for games, not when the user picks it in the system's aspect-ratio settings | The player asks for landscape for a landscape film and offers a rotate button and a "default orientation" setting; the app asks phones for portrait (`DeviceProfile`). On a tablet or an opened foldable at 36 none of that is honoured | Ready where it matters: the player lays out by the window (`MediaQuery.orientationOf`), keeps the film, its place and an open menu through a turn or a resize (test: "the window turns and resizes mid-film"), and its sheets now follow the window while open (they chose their form once; a turned phone left a 300 dp bottom sheet — fixed 13 Nov, `_PlayerSheetFrame`). The app's screens all work at any shape (two panes from 840 dp). Where the request is ignored — a tablet on Android 16, and a TV, where the player never asked — the rotate shortcut and the orientation settings are not offered (`DeviceProfile.orientationFixed`, 13 Nov; `test/orientation_fixed_test.dart`) |
| **Predictive back on by default**: `onBackPressed()` not called, `KEYCODE_BACK` not dispatched; back-to-home and cross-activity animations | Flutter's screens take Back through `PopScope` / `NavigatorPopHandler` (the player: a menu first, then the film; the shell; Settings' pane), which is the path predictive back uses. Native: `MainActivity.onKeyDown` takes media keys only. **`BrowserActivity` and `SignInWebViewActivity` go back through page history (and a full-screen video) in `onBackPressed()`** — at 36 Back would close the browser from the middle of a site | Done for 36: the two activities opt out (`android:enableOnBackInvokedCallback="false"` in the manifest, 13 Nov — what a 35 app gets anyway, so nothing changes now). The opt-out is not promised for ever (edge-to-edge's went at 36): the follow-up is an `OnBackInvokedCallback` (API 33+) registered only while there is a page or a full-screen video to go back to, so the system's own animation still plays when there is not |
| Edge-to-edge opt-out (`windowOptOutEdgeToEdgeEnforcement`) ignored | Not used; edge-to-edge has applied since the app targeted 35 | Nothing to do |
| `elegantTextHeight` ignored (native `TextView`s use the tall metrics) | Flutter draws its own text: no change. The browser's few native rows (address, menus) get taller lines in Burmese | Look at the browser in Burmese on an Android 16 phone after the raise |
| `ScheduledThreadPoolExecutor.scheduleAtFixedRate`: at most one missed run catches up | Not used in the Kotlin code | Nothing to do |
| `MediaStore.getVersion()` unique per app | Part of the library's change stamp (`MainActivity` "generation") | One full library rescan on the first start after the raise; nothing else |
| Safer intents, health permissions, Bluetooth bond intents | Opt-in / not used | Nothing to do |

**Not at 36 but next (Android 17, apps targeting 37)**: the large-screen
rule loses its temporary opt-out (`PROPERTY_COMPAT_ALLOW_RESTRICTED_RESIZABILITY`,
which Innocent does not use); **local network access needs the new
`ACCESS_LOCAL_NETWORK` runtime permission** (Nearby devices group) for TCP
and UDP to LAN addresses — Transfer (phone to phone, to a computer) and the
Network screen (SMB, FTP, SFTP) need a request and a refusal
path before targeting 37 (the loopback servers — the stream cache, the
local film server, the downloader's proxy — talk to 127.0.0.1, which is
not the LAN). Apps targeting 36 or lower keep an implicit grant.
(docs/devices_2026_11.md had said Android 17 applies the large-screen rule
to every app; Android's page says apps targeting 37.)

## How it was raised, and how to prove it
1. `android/app/build.gradle.kts`: `targetSdk = 36` (done 13 Nov).
2. To see the large-screen rule (on the old target too), on an
   Android 16 emulator (a tablet profile, smallest width ≥ 600) with a
   **debuggable** build (a release build cannot be toggled; on a user build
   a debuggable app can toggle the changes its target gates):
   `adb shell am compat enable UNIVERSAL_RESIZABLE_BY_DEFAULT com.innocent.media`
   (change 357141415), then play a landscape film upright, rotate, resize,
   open ⋮ and a sheet, Back. Predictive back has no toggle: try it on the
   raised debug build (system Back and the gesture in the player with a
   menu open, in the browser mid-site, on the first tab).
3. **Proved on Android 16, 13 Nov** (device lab 43420830536, results
   e13bc7bc): `EMU_API=36` in config.env (new; 34 by default), a Pixel C
   (2560×1800, smallest width over 600 dp), the app at target 36. The main
   tabs both ways round, then the lab film upright and sideways with the
   player audit's checks — ⋮ then Back closes the menu and the film stays,
   holding Next opens the repeat menu, CC's panel and Back: every flow
   passed (screens_large 7, its sideways 7, player_audit 43, its sideways
   52 steps), no ANR, no crash; the app laid out at 2560×1800 and
   1800×2560 as the device turned (its own orientation request ignored, as
   Android 16 does on a tablet). Not yet seen on a real Android 16 device.
4. Release notes: nothing a viewer notices, except a tablet that now turns
   with the film.

## Found while checking (13 Nov), for a later change
- A foldable started folded is a phone to `DeviceProfile` for the whole
  run (decided once at start), so on Android 15 and older an opened
  foldable keeps the phone's portrait request; at 36 on Android 16 the
  request is ignored there anyway. Following the change of smallest width
  needs a foldable to prove it on (an emulator's fold, or the owner's).
