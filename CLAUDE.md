# Notes for Claude Code: building ShootDesk on Kyle's Mac

Kyle is not a programmer. Explain in plain English, label things as verified, assumed or unknown, and change only what he asks for. Suggest other improvements; don't ship them unasked. Never call something "tested" when it only ran in the simulator.

Kyle works in the Claude desktop app (Code tab, local session, with computer use and the iOS Simulator pane), not in Terminal. Run commands yourself; don't hand him Terminal steps unless there's no other way.

Avoid fix loops. If the same error survives two attempts, stop and explain.

Current state, unbuilt changes and the verification list live in `HANDOFF.md`. Read it at the start of a session and keep it current as you go.

## Project

**Build setup**
- XcodeGen project: run `xcodegen` here to regenerate `ShootDesk.xcodeproj` after adding or removing files (`brew install xcodegen`).
- SwiftUI app, iOS 17+ deployment target, Swift 5 language mode, iPhone only. Built and run on the iPhone Duo simulator (iOS 27.1, Xcode 27.1).
- One third-party package, and only one: WhisperKit (Argmax, MIT licence, `https://github.com/argmaxinc/argmax-oss-swift`, product `WhisperKit`), for press-and-hold voice in Ask. Kyle chose it over Apple's speech recognition on Oct 20 2026 because it handles names better. Its speech model downloads to the phone on first use (not bundled). Ask Kyle before adding any other package.
- Maps are Apple Maps (MapKit); the Directions button opens the Google Maps app if it's installed, otherwise Google Maps on the web.
- Builds happen on Kyle's Mac (Xcode 27.1, the iPhone Duo simulator). GitHub no longer builds the app: the workflow was deleted Oct 19, so a push only stores the code. Steps in `HANDOFF.md`, "Build and run on the Mac".
- `RootView` still honors a `-startTab <tab>` launch argument, left over from the old GitHub screenshot tour. Nothing passes it now; don't build features on it.

**Source folders**
- `ShootDesk/Core/`: pure Foundation (models, Aryeo/Claude/weather/MassGIS clients, rules, evening check, on-disk order cache, widget data, Live Activity attributes). Also compiled into the widget. `Package.swift` + `Tools/CoreCheck` exist only to run Core on its own; Xcode ignores them.
  - Don't change business rules in Core without asking. They deliberately match Kyle's data dashboard.
- `ShootDesk/App/`: `ShootDeskApp` (entry, Home Screen quick actions), `AppModel` (@Observable, @MainActor; Stripe client, leave-by planner, delivery flags, Live Activity sync), `Booking.swift` (the only code that WRITES to Aryeo: Siri booking and the in-app Book a shoot screen), `ShootDeskIntents.swift` (Siri/App Intents, availability math).
- `ShootDesk/Views/`: all screens. One adaptive page per screen: the folded phone is one column; the open Duo is the same screen with more room (grids, two columns, side-by-side map), never a list-plus-copy split.
- `ShootDeskWidget/`: WidgetKit extension: Next Shoot (Home + Lock Screen), Evening Check, and the Live Activity (Lock Screen card with a leave-by countdown).

**Design system (Views/Components.swift)**
- Serif for addresses and big numbers: `Font.address(...)`. Gutters: `Gutter.of(size)` (28 open / 18 closed).
- Panels: `Theme.surface` (secondarySystemBackground) on `systemBackground` pages. Solid title bars only: `.slimBar("Title")` (no translucent bars).
- Buttons: `PrimaryActionStyle(prominent:)`, `.pressable`. Rows of cards: `Rail`. Big forms: `.adaptiveSheet` (sheet folded, full screen open).
- Anything that scrolls sideways goes through `SideSafeScroller` (or `Rail`, which uses it), never a bare `ScrollView(.horizontal)`. On the Duo, iOS 27 puts the tab bar in a vertical pill down the right edge and counts the strip under it as safe area; a bare horizontal scroller runs on underneath the pill.
- Duo half-open (laptop pose): `.foldWatch(halfOpen:)` reports it and `GeometryProxy.foldBand` gives the hinge's top and bottom (iOS 27.1 `onHingeChange` / `reservedRegions(kind: .division)`). The shoot page puts the photo above the fold and the details below.
- Copy: sentence case, plain words, no all-caps labels, no " · " separators.

**Keys**
- Aryeo, Claude and Stripe (restricted, read-only) keys are entered in Settings and stored only in the Keychain. Never hard-code, log or commit keys.

## Business rules (match the dashboard)

- Excluded: canceled orders, ghost orders, $0 orders, customers "Kyle Silva" and "Jordan Rebello" (App Review test account; Philip Rebello is real).
- Delivered = fulfillment status FULFILLED.
- Video = title contains "video" or "cinematic", OR starts with "essentials plus", OR contains "all in lux". Drone = title contains "drone".
- Stale = not delivered and more than 60 days old. Hidden from lists.
- Missing-deliverable flag: shoot ended 2–30 days ago, photos delivered in Aryeo, order includes video or a floor plan that isn't delivered. It is a one-day reminder: shown only while the shoot ended 2–3 days ago, and for at most 24 hours from when the app first found it, then it hides itself (Kyle, Oct 21 2026: he often shoots the exterior first and the rest much later). The 30-day outer limit no longer matters. "Not needed" dismisses it sooner.
- Availability: 8 AM to sunset, 30 minutes kept clear before and after each shoot for driving.

## Known simulator quirks (not app bugs)

- Clicks from automation on toolbar buttons in the Duo's side column are unreliable (sometimes two taps, sometimes none). Prefer in-page controls for anything important.
- Typing into the simulator from automation doesn't work reliably; test text fields by hand.
- Screenshots of the Duo: in the Closed pose `simctl io ... screenshot` needs `--display=primary` (without it the picture is black); in the Open and Partially Open poses use it without `--display`. Pictures sometimes lag a few seconds behind the screen; wait, or compare with the Device Hub window.
- Device Hub's Closed / Partially Open / Open buttons can go missing (seen Oct 19-20 after Device Hub quit on its own and was reopened, and in windows made with File > New Window). Fix: Device Hub menu > Quit and Keep Simulators Running, then open Device Hub again; the buttons come back and the simulator keeps its state.
