# ShootDesk handoff — Saturday, Oct 17 2026 (updated 11 PM: first cloud build is green)

ShootDesk is Kyle Silva's personal iPhone app (Horizon Home Media, real-estate photography) that replaces
Aryeo Go, built for the iPhone Duo. Project: `~/Documents/ShootDesk`. Read `CLAUDE.md` for the rules and the
design system; `README.md` says what the app does. This file is the state of play and the to-do list.

Kyle is not a programmer. Plain English. Label everything as verified / assumed / unknown. Change only what
he asks for and raise other ideas instead of shipping them. If the same error survives two attempts, stop and
explain. Never say "tested" for something that only ran in the simulator: say "checked in the simulator, not
on a real phone". He hates fix loops.

## Where things stand

Until Oct 17 the app was built and checked screen by screen in the iPhone Duo simulator (Xcode 27.1, iOS 27.1),
folded and open, light and dark. Nothing has run on a real phone yet; Kyle's Duo arrives around Oct 31.

On Oct 17 a batch of changes was written WITHOUT a Mac available. That night they compiled for the first time,
on GitHub's cloud Mac (Actions runs #1 and #2 both green; full log of #2, commit af08ecf, read line by line:
BUILD SUCCEEDED, every source file of the app and the widget compiled, no errors, one warning, see below).
Compiling proves the code is valid against Apple's iOS 27.1 SDK, nothing more. None of these changes has been
SEEN RUNNING yet, in any simulator or on a phone: call them "compiles on GitHub, not seen running".

## Oct 17 changes (compile on GitHub, not seen running): what each one is for

1. The folded Listings tab looked broken. Diagnosed from a saved simulator screenshot: on the folded Duo, iOS 27 draws the tab bar as a vertical pill down the right edge and
   counts the strip under it as safe area. Horizontal scrollers ignore the safe area along the way they scroll,
   so the "Upcoming" card rail ran underneath the pill (second card and its title hidden). The grid was fine.
   Fix: `SideSafeScroller` in `Views/Components.swift` measures the clear width and masks the scroller there.
   `Rail` uses it, and so do every other sideways scroller (shoot page "This house before", hourly forecast
   chips, the map's town card, the Book a shoot date chips).
2. Haptics: a medium thump on "Book it" (`App/Booking.swift`) and on "On my way" (`Views/StopDetailView.swift`).
   The card-to-page zoom transition already existed (`zoomSource`/`zoomDestination`, iOS 18+); never confirmed visually.
3. Choose the cover photo per shoot: press and hold a photo in the shoot page grid → "Use as cover photo".
   `CoverChoice` + `Job.coverImage` in `Core/Domain.swift` (saved in UserDefaults, order id → image id);
   `AppModel.setCover` re-issues jobs so every card redraws; "Cover" badge + context menu in `Views/PhotosCard.swift`.
4. Background refresh: `.backgroundTask(.appRefresh("com.horizonhomemedia.shootdesk.refresh"))` in
   `App/ShootDeskApp.swift`, `AppModel.backgroundRefresh()` (newest 100 orders only, no full sync, no weather),
   `OrderStore.quickRefresh`, plus `UIBackgroundModes: fetch` and `BGTaskSchedulerPermittedIdentifiers` in
   `ShootDesk/Info.plist` and `project.yml`. iOS decides timing: "usually fresh, never guaranteed".
5. Duo half-open ("laptop") pose: `FoldWatch` + `GeometryProxy.foldBand` in `Views/Components.swift` use the
   iOS 27.1 `onHingeChange` / `DeviceHinge.status == .partiallyOpen` / `reservedRegions(kind: .division)` APIs.
   The shoot page (`StopDetailView`) shows the photo or map above the fold and the details scrolling below it.
   THE API NAMES CAME FROM A THIRD-PARTY EXAMPLE REPO (github.com/artemnovichkov/iPhone-Duo-by-Examples), not
   Apple docs. Verified Oct 17: they compile against Apple's iOS 27.1 SDK (they sit inside
   `if #available(iOS 27.1, *)`, which the compiler still checks), so the names exist. Unknown: whether they
   behave as expected. Only the Partially Open pose on the Mac (or the real phone) can show that.
6. Widgets (`ShootDeskWidget/NextShootViews.swift`, `NextShootWidget.swift`): package name under the street on
   the small widget and on each "Coming up" row of the large widget; small widget's street is now one line so
   it doesn't overflow; large listed first in supported sizes (Kyle wants large as the default; iOS may still
   open the picker on small — tell him either way).
7. Photo cache raised to 2 GB on disk (`App/ShootDeskApp.swift`). Kyle's call.
8. `CLAUDE.md` gained the rules for `SideSafeScroller` and the fold helpers.

## How building works now (Oct 17 2026): GitHub builds it

Claude Code in the cloud runs on Linux and cannot compile or run an iOS app itself. Instead, every push to
`main` runs `.github/workflows/build.yml` on one of GitHub's cloud Macs (the `xcode-27` image; its "Xcode 27.1"
is the 27.1 Release Candidate, build 27A9275, per the run log). The loop from a phone is: edit → commit → push →
open the repo's Actions tab → green check or red X.

- A green check means the app COMPILES (for the simulator, unsigned) and, if the run's summary page says
  "Launch check: the app opened on ...", that it also opened on a simulator on every tab, light and dark, without
  crashing. It does not mean it looks right or works; that still needs eyes on the Duo simulator (Kyle's Mac) or the
  real phone. Say "compiles and opens on GitHub", never "works". If the summary says "Launch check skipped", only the
  compile is proven. A build for the real phone needs Kyle's signing, so it happens on his Mac.
- On a red X: read the "Errors and warnings" step of that run for compile errors. If the summary says "Launch check
  failed", read the "Open the app on a simulator" step (it prints the error lines iOS logged about the app) and
  `launch-check/app-log.txt` plus `launch-check/crashes/` (if present) in the build-output artifact. Claude Code in the
  cloud reads runs and job logs itself through the GitHub connector; Kyle doesn't need to paste anything. Fix, push,
  wait. Same error twice → stop and explain.
- After compiling, the workflow opens the app on a simulator once per tab (Today, Listings, Customers, Money, Ask,
  Settings), in light and then dark: 12 launches, a screenshot of each, launched with the `-startTab <tab>` argument
  that `RootView` honors for exactly this (added Oct 17; nothing else passes it). The screenshots are pushed to the
  `screenshots` branch, github.com/ksremedia-spec/ShootDesk/tree/screenshots, one commit replaced on every build
  (the README there shows them inline, fine on a phone), and are also in the build-output artifact with
  `launch-check/app-log.txt`. It tries the iPhone Duo first; GitHub's image has the Duo device but only the iOS 27.0
  simulator, which the Duo refuses, so it opens on a regular iPhone already on the runner (the image has iPhone 17,
  17e, 18 Pro and Air; the summary line says which, and why it's not the Duo). Assumed: the Duo starts being used by
  itself once the image gets iOS 27.1. With no Aryeo key in the cloud every tab shows its empty state; on a regular
  iPhone the 5th and 6th tabs may sit under a "More" tab, so Money, Ask and Settings may appear inside More.
  Red only if the app crashed (a launch the simulator refused and a crash report, or the process gone when checked);
  any simulator problem skips with a message instead. The boot wait is capped at 5 minutes for the same reason.
  Claude Code in the cloud can't download artifacts (network rule) but CAN read the screenshots branch through
  raw.githubusercontent.com, so it can look at the pictures and describe them.
- Known warning, not an error: `App/Booking.swift:330`, Siri booking's `requestConfirmation(result:...)` is
  deprecated (Apple suggests `requestConfirmation(conditions:actionName:dialog:)`). Deprecated still works. Left
  alone on purpose: it's booking code and Siri booking hasn't been tried on a phone. Raise it, don't change it unasked.
- GitHub's Mac minutes are free on a public repo. On a private repo they count 10x against the plan's free
  minutes (as far as I know: 2,000 min/month on the Free plan, so about 200 Mac-minutes, roughly 20–30 builds).
  The repo IS public (checked Oct 17), so builds cost nothing; one takes about 2 minutes. Public also means anyone
  can read the code and these notes. No keys are in the repo (checked Oct 17); keep it that way.

## Build and run on the Mac (needs Xcode 27.1)

The Xcode project file isn't committed (see .gitignore); `project.yml` is the recipe. On a fresh clone, or whenever
source files are added or removed, run `xcodegen` in the project folder first (`brew install xcodegen` once).
Then put your Apple Team ID in `project.yml` under DEVELOPMENT_TEAM if Xcode asks for signing.

    cd ~/Documents/ShootDesk
    xcrun simctl list devices available | grep -i duo        # find the iPhone Duo simulator's name/UDID
    xcodebuild -project ShootDesk.xcodeproj -scheme ShootDesk \
      -destination 'platform=iOS Simulator,name=iPhone Duo' build 2>&1 | tail -40
    xcrun simctl boot "iPhone Duo"; open -a Simulator
    # install + launch the built app (path printed by xcodebuild, under DerivedData .../Build/Products/Debug-iphonesimulator/ShootDesk.app)
    xcrun simctl install booted <path to ShootDesk.app>
    xcrun simctl launch booted com.horizonhomemedia.shootdesk
    xcrun simctl io booted screenshot ~/Desktop/shootdesk-check.png

Unknown: whether `simctl` can fold/unfold the Duo or set the half-open pose. In Xcode's device window
(Device Hub) there are Closed / Partially Open / Open buttons; if there's no command-line way, ask Kyle to
press them while you take screenshots.

## Verify, in this order (take a screenshot for each)

0. No Mac needed: open github.com/ksremedia-spec/ShootDesk/tree/screenshots after a green build. Twelve pictures,
   every tab light and dark, on a regular iPhone with no key: empty states only. Proves the app opens; nothing else.
1. FOLDED Listings tab: the Upcoming rail must stop at the vertical tab-bar pill. Scroll the rail to its end:
   the last card fully visible, not under the pill. Then: Today tab rails, an agent page rail (Customers), a
   shoot page's "This house before" rail and hourly forecast chips. Check the OPEN pose too (side column on
   the right). If the mask cuts too early or not at all, the ruler's `safeAreaInsets.trailing` reading is
   wrong: print it and rethink before changing anything else. The one sideways scroller NOT on
   `SideSafeScroller` is the filmstrip in the full-screen photo viewer (`GalleryViewer` in `PhotosCard.swift`);
   it's a full-screen cover where the tab-bar pill isn't drawn, so assumed fine. Glance at it folded.
2. Widgets: add Next Shoot small and large to the simulated Home Screen. Package line present; small doesn't
   overflow; note which size the picker opens on.
3. Cover photo: shoot page → press and hold a grid photo → Use as cover photo → the Listings card and the hero
   change; the "Cover" badge moves; "Use Aryeo's first photo" undoes it; survives relaunch.
4. Background refresh: Xcode → Debug → Simulate Background Fetch with the app running; console shows a quick
   refresh, no crash. Real timing can't be checked in the simulator — say so.
5. Half-open pose: Partially Open → shoot page: photo above the fold, details below.
6. Haptics can't be felt in the simulator — "simulated, not checked on a real phone".
7. Update the Status section of `README.md` and this file. Keep `CLAUDE.md` "Known quirks" current.

## Security rules (do not bend these)

- Keys (Aryeo, Claude, Stripe restricted key) are typed by Kyle into Settings and live only in the Keychain.
  Never write a key into a file, a log, a commit or source. Never type a real key into the app for him.
- The only code that writes to Aryeo is booking (`App/Booking.swift`), after Kyle confirms, with `notify: true`.
  In testing never press the final "Book it": it creates a real order and emails a real agent.
- Reminders Kyle still owes himself: delete Aryeo test order #1857; rotate the Aryeo API key and the Stripe
  secret key that were exposed earlier. Remind him once per session until done.
- `Rules` in `Core/Domain.swift` match his business dashboard; don't change them without asking.

## Not checked anywhere yet

Siri, widgets, notifications, the Live Activity, quick actions, haptics and real drive times on a real phone;
typing an address into Book a shoot (the simulator wouldn't take typing from automation); an actual booking.

## Parked ideas (Kyle has NOT asked for these; raise, don't build)

- Placeholder pictures for shoots with no photos yet: Apple Look Around street image with a satellite snapshot
  fallback. Kyle liked the idea. No Zillow (terms + other photographers' work). Google only if Apple's coverage
  around Dartmouth / New Bedford is patchy.
- Widget copy polish: "NEXT SHOOT" / "COMING UP" all caps and " · " separators break the app's copy rules; ask first.
- Should the full-screen photo viewer stay open when the phone is unfolded? (It closes now.)
- From the Oct 17 brainstorm, not picked: sun check for the front of the house, shot list per package, one-tap
  wrap-up text, house notes that come back, money per hour by package/town, quiet-agent nudges, owed-to-you
  list, assessor house facts, twilight slot suggestions. CarPlay stays v2. Kyle does not want the full-page widget.
- Asked Kyle Oct 17, waiting on his answer: (a) the Next Shoot widget still offers the full-page size on iOS 27
  (`.systemExtraLargePortrait` in `NextShootWidget.swift`, drawn with the large layout and up to 9 "coming up"
  rows instead of 3); remove it from the picker? He asked for a plain-English explanation first. (b) swap the
  deprecated Siri confirm call once Siri booking can be tried on the phone. (The cloud "does it open" check was
  asked for and built Oct 17; see "How building works now".)
- Kyle asked Oct 17 to "show every page screenshots". The cloud can only show empty states on a regular iPhone
  (built as the tab tour above). Real pages with his shoots, on the Duo, folded and open, need his Mac. If he wants
  filled-in cloud screenshots, that means a demo-data mode with made-up shoots: a real feature, ask first.
