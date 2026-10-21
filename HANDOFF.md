# ShootDesk handoff — Monday, Oct 19 2026 (first Mac session: Oct 17 changes seen running in the Duo simulator)

ShootDesk is Kyle Silva's personal iPhone app (Horizon Home Media, real-estate photography) that replaces
Aryeo Go, built for the iPhone Duo. Project on the Mac: `~/Documents/ShootDesk-github`, a clone of GitHub made Oct 19.
(The older `~/Documents/ShootDesk` copy was an out-of-date, non-git version; compared Oct 20 and found nothing missing
here, and moved to the Trash the same day at Kyle's request. This folder is the only project now.) Read `CLAUDE.md` for the rules and the
design system; `README.md` says what the app does. This file is the state of play and the to-do list.

Kyle is not a programmer. Plain English. Label everything as verified / assumed / unknown. Change only what
he asks for and raise other ideas instead of shipping them. If the same error survives two attempts, stop and
explain. Never say "tested" for something that only ran in the simulator: say "checked in the simulator, not
on a real phone". He hates fix loops.

## Where things stand

Until Oct 17 the app was built and checked screen by screen in the iPhone Duo simulator (Xcode 27.1, iOS 27.1),
folded and open, light and dark. The Duo itself arrives on launch day (Kyle, Oct 19; date not given). Meanwhile Kyle
runs the app on his regular iPhone (iPhone 16 Pro Max), first installed from Xcode on Oct 19 from the OLD folder
`~/Documents/ShootDesk`. Compared Oct 20 (read only): that folder is an older copy (files last changed Oct 15-16),
before the Oct 17 changes; nothing in it is missing here. On Oct 20 a session built this project (commit a41f149
plus nothing else) for the phone and installed it over the old one: `xcodebuild ... -destination
'id=00008140-0002190E11E1801C' DEVELOPMENT_TEAM=6YCK9MG5RD -allowProvisioningUpdates build`, then
`xcrun devicectl device install app` and `device process launch` (the team id is from Kyle's own Oct 19 phone build;
`project.yml` still leaves DEVELOPMENT_TEAM empty). Installed and launched; not looked at on the phone by Claude. That phone can't show anything Duo-specific (folding, the open
layout, the side tab pill), and nothing on it has been checked systematically yet; only what Kyle reports.

On Oct 17 a batch of changes was written WITHOUT a Mac available. That night they compiled for the first time,
on GitHub's cloud Mac (Actions runs #1 and #2 both green; full log of #2, commit af08ecf, read line by line:
BUILD SUCCEEDED, every source file of the app and the widget compiled, no errors, one warning, see below).
Compiling proves the code is valid against Apple's iOS 27.1 SDK, nothing more.

On Oct 19 they were built on Kyle's Mac and run in the iPhone Duo simulator with his real Aryeo data. Results are in
"Oct 19 Mac session: verify results" below. Still nothing on a real phone.

## Oct 19 Mac session: verify results (checked in the simulator, not on a real phone)

Build: `xcodegen` + `xcodebuild` with Xcode 27.1, BUILD SUCCEEDED, only the known Siri deprecation warning. Run on the
Duo simulator `1DBDC341-4076-48E1-9445-FC21C9F1AF1B` (the one with Kyle's keys and cached orders; the other Duo,
`FA6CE7DE-…`, is empty). No code was changed in this session.

1. Sideways rails stop at the tab pill: PASS. Folded: Listings "Upcoming" (scrolled to the last of 10 cards), Today
   "This week" (last card 9 Calderwood Ave) and "Recently delivered" (last card 250 Davis St), and a shoot page's
   "This house before" (283 Union St, 11 other orders), all end at the pill. Open: Listings Upcoming ends clear of the
   pill. Not checked: the agent page "Shoots" rail scrolled to its end (start looked right, swipes kept missing it),
   and the hourly forecast chips (no shoot opened showed them). Filmstrip in the photo viewer looked fine folded.
2. Widgets: PASS. Small and large Next Shoot both show the package line; small street fits on one line; large lists
   3 "Coming up" rows each with its package. Found: the small widget's top label truncates to "TOMORR…" when the
   DRONE badge is shown (not fixed; ties in with the parked all-caps widget copy question). Unknown: which size iOS's
   widget gallery opens on; the widgets were made by resizing the app icon (iOS 27 long-press menu), which starts small.
3. Cover photo: MOSTLY PASS, one bug. Press and hold → "Use as cover photo" saves (UserDefaults `coverChoices`,
   order id → image id, verified in the plist), the shoot page hero changes at once, survives relaunch, and
   "Use Aryeo's first photo" clears it (verified; 283 Union St / order 1823 is back to Aryeo's first photo).
   BUG: the "Cover" badge in the photo grid stays on the old photo until the app is relaunched. Likely cause
   (assumed): `PhotosCard` takes `job: Job`, and `Job` equality doesn't include the cover choice, so SwiftUI skips
   redrawing the grid after `AppModel.setCover` hands out fresh jobs. Not fixed; ask Kyle. Not checked: the Listings
   card (couldn't find it among 688 past shoots without typing into search).
4. Background refresh: NOT DONE. Simulating it needs a debugger attached to the app, and this Mac has developer mode
   off (`DevToolsSecurity -status`), so the attach waits for Kyle's password. Either run
   `sudo DevToolsSecurity -enable` (Kyle types his password) or run from Xcode and use Debug → Simulate Background
   Fetch, approving the prompt. Note `backgroundRefresh()` logs nothing; judge it by `orders.json`/`sync.json` in the
   app's Application Support/ShootDesk folder getting a new timestamp, and the app staying alive.
5. Half-open pose: FIXED in the simulator (committed Oct 19). Device Hub's Partially Open pose made the
   shoot page go completely black. Cause VERIFIED with a temporary print (since removed): in that pose the
   simulated Duo folds like a book. `reservedRegions(kind: .division)` returned one active 40 pt wide strip,
   x 455.5, y 0, height 669 (the full screen height), with the view 867 x 635. `laptop` reads only the strip's top
   and bottom, so the photo got 0 height, the details got 0 height, and the spacer filled the page with black.
   Kyle chose (Oct 19): when the fold runs top to bottom, show the normal shoot page and ignore the fold.
   `GeometryProxy.foldRunsTopToBottom` (strip taller than wide) in `Views/Components.swift`; `laptop` in
   `StopDetailView` shows `page` when it's true. The photo-above, details-below layout is kept for a fold that runs
   side to side. Checked: the Partially Open shoot page (6 Morrison Way) now draws the normal two-column page and
   scrolls; the hourly forecast chips showed there too. Not checked: Closed and Open poses after the change
   (Device Hub access wasn't available; those poses don't use the changed code), and anything on a real phone.
   Unknown: whether the real Duo ever reports a side-to-side fold, which is the only case the old layout still runs.
6. Haptics: can't be felt in the simulator; not checked on a real phone.

## Oct 19 full simulator pass (checked in the simulator, not on a real phone)

Kyle asked for everything left to be checked before the phone arrives. Same Duo simulator, his real data, the
current build. Every screen in all three poses (Closed, Partially Open, Open); every tab in dark and light
(the app's own Appearance setting was switched to Light for this and set back to Dark afterwards).

PASS: Today; Schedule; Open times (the driving-gap maths checked by hand against the Oct 20 and Oct 22 shoots);
Upcoming check (the wind warning only on the shoot with drone work); Listings gallery and map (towns split as you
zoom; a town card opens its shoots); the shoot page with its hourly forecast chips, photo viewer, swipe between
photos, slideshow (stops on the photo it reached) and Listing kit (town record, plus "Write it" drafted an MLS
description with Claude); Customers (list folded, table open) and the agent page; Money (loaded from Stripe);
Ask (one real question, answered from live data); Settings. Book a shoot opens and draws in every pose.
Leftovers from the first pass: the agent page "Shoots" row scrolled to its end stops at the tab pill (Aimee
Rose, last card Wildwood Pl fully visible); the cover photo shows on the Listings card (129 Huttleston Ave, set
and then put back to Aryeo's first photo, `coverChoices` empty again); the half-open shoot page draws the normal
page.

Found in the pass, all five FIXED the same evening at Kyle's request (checked in the simulator, not on a phone):
- Cover badge: the "Cover" label stayed on the old photo until the page was reopened. Cause: the shoot page holds
  a `Job`, and a job with a new cover still compares equal, so SwiftUI skipped the redraw. Fix: `AppModel.coverVersion`
  goes up on every cover change and `AppModel.coverID(for:)` reads it; `StopDetailView` passes that to `PhotosCard`
  (new `coverID` parameter). Checked: set a cover and the label moves at once; "Use Aryeo's first photo" moves it
  back at once; `coverChoices` saved and cleared. (A first try, passing the id without the counter, fixed setting
  but not undoing.)
- Ask (open Duo) summary tiles: "Money: Not connected" and "Missing: All delivered" while still loading. Now the
  Money tile says "Checking…" while Stripe loads, "Couldn't reach Stripe" if it fails, and "Not connected" only
  with no key; Missing says "Checking…" until the first delivery check finishes (`AppModel.flagsChecked`) and
  "Not checked" if Aryeo couldn't be reached. Checked: "Checking…" then $4,545 and 1 missing; during a real Stripe
  timeout the tile said "Couldn't reach Stripe".
- Listings map "0 shoots in 0 towns": the header now says "Loading your shoots…" when there are none yet, and the
  camera moves to the usual opening view once they arrive. The real cause of the wait turned out to be speed: the
  bubble maths re-grouped all 692 shoots for every bubble size, which kept a processor core at 99% for 30+
  seconds. Bubble sizes are now worked out once per redraw. Checked folded: bubbles drawn within 5 seconds, the
  app idle afterwards.
- Listing kit margins: now `Gutter.of(size)` (28 open, 18 folded) instead of a fixed 16. Checked open.
- Map bubbles overlapping: bubbles now merge whenever they would touch (no 20% allowance), keep merging after a
  bubble grows, and the map notices width changes as well as height. Checked open: the 96 sits beside the 339,
  no longer half under it; some bubbles touch at the edges. Not rechecked open after the speed fix (Device Hub's
  replacement window had no pose buttons); the speed fix doesn't change where bubbles go.

Oct 20, found by Kyle on a regular iPhone (his screenshots: bottom tab bar with "More", real signal and battery),
FIXED: in Listings "Past shoots", a row with a blue date card (a shoot with no photos) came out wider and taller
than the other rows, the date card nearly touching the screen edges. Cause: `ShootCard` put `.aspectRatio(16/10,
contentMode: .fill)` on the artwork itself, and `DateArt` stretches to whatever it's offered, so it spilled past its
column and the photo beside it stretched to match. Fix (`Views/Components.swift`): a fixed 16:10 box the column's
width with the photo or date art laid over it, and the time label as a second overlay. Checked in the simulator,
folded: the Oct 2 row (298 Potomska Rd, 270 Tinkham St) lines up with the rows above; the Upcoming and This week
rows (date cards with the time label) look the same as before. Not checked: the open Duo (Device Hub's window came
back without pose buttons), and on Kyle's iPhone (needs the new build installed there).

Oct 20, reported by Kyle on his iPhone, FIXED: after a night away, Today's "Recently delivered" and "Updated 12 hours
ago" stayed old after opening. Cause (verified in the simulator by backdating `sync.json` 12.5 hours): opening the
app after 12+ hours starts the full download of every order (`OrderStore.needsFullSync`), which took 63 to 79
seconds here, and nothing on screen changed until it finished; leaving the app in that minute stops it and the next
open starts over. Fix (`App/AppModel.swift` `refresh`): when a full download is due, grab the newest 100 orders
first (`quickRefresh`) and update the screen, then do the full download; if only the full one fails, no error is
shown. Follow-up checks (deliveries, Stripe, drive times, the upcoming check) now start after the first download
that works (`applyFreshOrders`). Today's footer says "Updating… (last updated ...)" only while what's on screen is
more than 5 minutes old. Checked in the simulator: newest orders saved 10 seconds after launch (was 63), full
download done at 79; footer "Updated 3 seconds ago" with the full download still going. Installed on Kyle's iPhone Oct 20 (it was locked, so it didn't open by itself). Kyle confirmed Oct 20 that it worked on his iPhone (his report; the
overnight case, opening after 12+ hours, still to be seen). Not seen: the brief
"Updating…" line (over too fast to screenshot). Not checked on the phone yet beyond installing it.

## Oct 20: the new Ask (asked for by Kyle; checked in the simulator, voice not tried with speech)

Kyle picked (Oct 20): polished chat look; tappable shoots and agents; knows more of his day; charts; faster and
remembers; press-and-hold to talk with WhisperKit; sounds; haptics; smooth streaming; follow-up chips.
- Look (`Views/AskView.swift`, `Views/AskAnswer.swift`): question bubble, Claude's reply in a panel with a sparkle
  that pulses while it writes, lists, copy and share, 2-3 follow-up chips under the last answer.
- Cards and charts: the prompt (`Core/Assistant.swift`, `AskContext.system`) asks Claude for `[[shoot 1855]]`,
  `[[agent Full Name]]`, one ```chart {json}``` block and a `[[next: a | b | c]]` line; `AnswerParser` turns them into
  a tappable shoot card, an agent card with call and text buttons, a Swift Charts bar or line chart, and the chips.
- More of the day (`App/AskToday.swift`): each question carries the week's bookings with leave-by times, open times
  (same maths as Open times), the upcoming check and missing deliverables.
- Faster: the big data block no longer has the clock in it and is marked for prompt caching (5 minutes); the whole
  conversation is cached too. Effort `medium`, plus `fallbacks: "default"` (beta `server-side-fallback-2026-07-01`)
  so a safety-check decline is retried on another model. Verified in the simulator: first question wrote 61,993
  tokens to the cache, the next two read 61,209 from it (the app logs `ShootDesk Claude usage:` lines).
- Remembers: the current conversation is saved to `Application Support/ShootDesk/ask.json` (last 40 turns);
  "New question" clears it.
- Voice (`App/Voice.swift`): hold the mic, talk, let go to send, slide up to cancel; words appear while you hold.
  WhisperKit 1.1.1 (`project.yml` packages), model `openai_whisper-large-v3-v20240930_626MB`, downloaded once on
  first use (606 MB on disk, kept out of iCloud backups); agents' names and towns are passed as a hint. Settings >
  Ask can remove it. Checked in the simulator: the download prompt, the download (about 20 s on the Mac's
  connection), loading, and iOS's microphone question with our wording. NOT checked: talking to it (needs a person;
  the simulator's mic prompt was left for Kyle), and how long the first load takes on the phone.
- Sounds (`App/AskSounds.swift`): send, answer ready, mic on and off, made in code as soft tones, played as system
  sounds (quiet on silent), Settings > Ask turns them off. Haptics on send, mic, and answer done.
- Seen in the simulator: answers to "When am I free this week?" (open days and gaps matched Open times, three shoot
  cards), a Stripe question, and a follow-up chip (tapped by the simulator's swipe, not on purpose); open and
  folded. Installed on Kyle's iPhone Oct 20. Not seen: a chart (no question asked yet that called for one), an agent card's call/text on a phone.

## Oct 20 design audit (Kyle: "spacing on top and sides" still off on the Duo)

Code read screen by screen (a read-only audit agent) plus screenshots of every tab, the open Duo held tall
(about 670 pt wide, tab bar along the bottom) and held wide (about 950 pt). Fixed:
- Ask and Settings chose their side-by-side layout from the size class only, so on the open Duo held tall the
  360 pt question list squeezed the chat to a strip and Settings' right column was cramped with a 64 pt gap. Now they
  switch on real width (`Gutter.sideColumnWidth` = 820): two columns only when held wide.
- Search bars: Listings and Customers used the system search bar, whose margins don't follow ours. New `SearchBox`
  (`Views/Components.swift`) sits on the page gutter.
- Gutters: Customers table 12 -> `Gutter.of(size) - 10` (the table's own row inset makes up the rest), folded
  Customers rows, Ask chat (22/16) and composer (12), Settings forms, Money (hard-coded 28/18), the Open times offer
  bar, the folded map town card: all on `Gutter.of(size)` now.
- Top spacing under the title bar: Schedule 12 and Listings 14 -> 16, like the other pages.
- Open Duo stretch: Listing kit is a centred column of at most 720 pt; Open times' intro and length picker are capped.
Checked in the simulator: open Duo tall (Listings, Customers, Ask, Settings, Money) and wide (Listings, Customers,
Ask, Settings). Audit continued Oct 20 (simulator): folded (all six tabs, Upcoming check, shoot page), half-open (all
six tabs, shoot page) and open (Schedule, Open times, Book a shoot, Listing kit) all look right, except Settings: a set
trailing `contentMargins` on a Form ignores the tab bar's strip, so its panels ran under the tab bar folded and in the
wide right column. Fixed by leaving the trailing side on the system margin (leading stays on the gutter). Open times'
Thursday showing only "Until 12 PM" is correct (the 4:30-to-sunset gap is shorter than the 1.5 hr picked). Not
rechecked after this pass: the agent page and map (taps from automation kept missing; neither changed). Left alone: the system's own title text sits about 8 pt left of the
gutter on the wide open Duo (iOS places it); the photo viewer's thumbnail strip (full screen, no tab bar there);
section spacing still varies 18-30 between screens (raise if Kyle wants it uniform). Also noticed, not a layout
issue: the Upcoming check says "Nothing coming up" until its first check has run after launch.

Oct 20, Kyle: the shoot page's photo now fades into the page at the left and right edges too (4% of the width
folded, 7% open), like it already did at the bottom, so it has no hard edge against the strip by the tab bar
(`heroArt` in `StopDetailView`). Checked in the simulator, open Duo held wide.
Claude logo: Kyle decided (Oct 20) to use the official Claude spark in his personal app; he was told Anthropic's
trademark guidelines ask for approval and that the repo is public. File: `favicon.svg` from claude.ai (2,558 bytes,
the spark in #D97757), stored as `Resources/Assets.xcassets/ClaudeSpark.imageset/claude.svg`; `ClaudeMark` in
`Views/Components.swift` draws it. Used: Ask's title bar ("Claude" label), Ask's intro, beside each answer (it turns
gently while Claude writes), the shoot page's Listing kit button (orange spark), and Listing kit's own button
("Write it with Claude", white). Kyle decided (Oct 20) to keep
the app icon as it is: no spark on it.
The Stripe mark (Money) and the Claude label (Ask) looked boxed in: iOS 26+ puts a glass bubble behind every
title-bar item. `TitleBarMark` (`Views/Components.swift`) turns it off (`sharedBackgroundVisibility(.hidden)`).
Checked in the simulator, open Duo held wide.

Oct 21, Kyle: Listings looked "very empty" unfolded. Cause: the Missing row (shoots missing a video or floor plan)
showed one small card with the rest of the wide row blank; it only appears after the delivery check finishes, so the
audit screenshots never caught it (not caused by the spacing pass, which only moved the search bar and added 2 pt).
Now, with one or two flags, Listings and Today show a wide `MissingCard` (photo left; address, agent, what's missing,
shot date right): one fills the row, two share it; three or more keep the sideways row. Checked in the simulator,
open Duo held wide. Then, at Kyle's request, Today's "This week": up
to 3 shoots (open) or 1 (folded) share the width in a grid; more keep the sideways row. Checked open, two shoots.

Oct 21, Kyle changed a business rule: a missing-deliverable flag (Missing on Today and Listings, the Today badge) is a
one-day reminder. It shows for 24 hours from when the app first found it, then hides itself; he often shoots the
exterior first and the rest weeks or months later. `FlagFirstSeen` (`App/AppModel.swift`, UserDefaults
`flagFirstSeen`, order id -> date) records the first sighting; ids that stop being flagged are forgotten, so a later
re-flag gets a new day. The one notification per flag is unchanged. CLAUDE.md's rule updated. Checked in the
simulator: shown when new; with the date set 25 hours back (via `simctl spawn ... defaults write`; editing the plist
file directly doesn't reach the running cache), Missing and the badge were gone. On Kyle's phone, flags showing now
get their day starting from the first launch of this build.

Oct 21, Kyle: new card art for shoots with no photos yet (`PlaceholderArt` in `Views/Components.swift`, used by
`ShootCard`), replacing the blue gradient date card on every shoot card (Listings, Today, Upcoming, agent pages).
Styled like an Apple Calendar event: `Theme.accent` tint with a solid blue stripe on the left; the time in big serif,
the date in blue, the agent on its own line (long names fit), and what the order includes ("Photos, drone, video")
at the bottom. Under the card only the town shows (the agent is on the card); the small time chip is dropped there.
Photo cards are unchanged (Kyle: "just change the placeholder cards for now"). Kyle turned down: sun/light hints,
the house number, the agent on photo cards. Still on the old date art: the shoot page hero with no photo and no map
position, Ask's small shoot chips (`DateTile`). Checked in the simulator, folded, dark mode. Not checked: light mode,
the open Duo.

Oct 21, Kyle: an order with no appointment time isn't a confirmed shoot, so Listings' Upcoming shows only booked
shoots with a time (was: those plus "date to be set" orders at the end). Simulator: Upcoming 11 -> 4. Those orders
still show in search and on the agent's page; Today already required a time.

Oct 21, Kyle: sideways rows (Upcoming, This week, Recently delivered, every `Rail`/`SideSafeScroller`) now fade out
over the last 36 pt before the tab-bar pill instead of ending on a hard line; with no pill (open Duo held tall, tab
bar at the bottom) the edge stays as it was. Checked in the simulator, folded. Kyle asked whether it clashes with the
Duo's own fold/unfold animation (the moving half turns see-through): assumed not. Reports describe that animation as
drawn by iOS over whatever the app shows, with no app API, and the fade is ordinary app content that follows the
measured width. Not seen on a real Duo.

Oct 21, Kyle: (1) the old Missing reminder still showed on his phone, because the "one day" counted from the
first launch of the new build. Now a flag shows only while the shoot ended 2-3 days ago (and at most 24 hours from
first sighting), so older ones are gone at once; CLAUDE.md rule updated. (2) Folded tab bar: tried a bottom bar
(`toolbarVerticalBehavior(.disabled)`) and then a single top-right tab button with the bar hidden; Kyle disliked
both and they're gone, back to iOS's side pill. Learned: on the folded Duo the right-hand strip is iOS 27.1's
vertical bar area (clock, battery, back and toolbar buttons, tabs), so hiding the tabs doesn't give the width back;
only moving all bars to the top and bottom would. Instead, to fill the folded screen: no title row on the Today,
Listings, Customers, Money and Settings front pages (`.foldedTitleHidden()` in `Views/WideViews.swift`; Money's
Stripe mark moves into the page), and the folded gutter is 14 instead of 18 (`Gutter.of`). Ask too (Kyle asked): folded,
its title row is gone, the new-question button sits at the left of the input bar, and the "Claude" label shows only
on the open Duo (the spark is beside every answer). Checked in the simulator, folded.

Oct 21, Ask is voice only (Kyle won't type much): the text box is gone; one big talk button (hold to ask) at the
bottom, with a soft fade behind it so answer text melts away under it; the suggested questions still work by tap.
Folded, the new-question button is a bottom-bar toolbar item, which iOS 27.1 places in the right-hand strip under
the clock (Kyle asked for just above the tab bar; iOS picks the spot). Claude: effort `low` for snappier answers
(about 6 s to the first words, 9 s done in the simulator); the prompt now expects speech-to-text and only asks one
short question back when it truly can't tell what Kyle means (not tested: needs a spoken question). Short answers
scroll up when done so their follow-up chips clear the button.
Bug fixed: voice asked to download again after every reinstall or update, because the model's full folder path was
saved and the app's path changes on reinstall. Now saved relative to `Application Support/WhisperKit` (old saved
paths are read by their tail). Checked in the simulator: no download prompt after reinstall. Holding to talk in
the simulator uses the Mac's microphone, so it may work there; not tried.

Oct 21, Kyle: progress for big saves to Photos ("Save all" photos, and saving a video from the viewer; single photos
don't). `App/Transfers.swift`: `TransferCenter` (on `AppModel.transfers`) tracks one save, asks iOS for background
time, and drives a small pill bottom left on every tab (ring + "12 of 34", ticks and hides 4 s after) and a Live
Activity (`TransferActivityAttributes` in `Core/NextShoot.swift`, `TransferLiveActivityWidget` in the widget): Lock
Screen card (redone Oct 21 after Kyle called the spacing broken: three padded rows, status and "25 of 34", the
address, the bar), Dynamic Island ring and percent. Videos now download through
`ProgressDownload` (URLSession task progress). If iOS stops the app in the background the card says "Paused. Open
ShootDesk to finish." Checked in the simulator: Save all 34 on 129 Huttleston Ave, the pill counted up, and the Lock
Screen card kept counting after leaving the app (iOS asked "allow Live Activities from ShootDesk?" the first time;
left for Kyle). Not seen: a video save, the Dynamic Island (the simulated Duo has none on screen), the paused case.
The simulator's Photos now holds those 34 test copies.

Oct 21, voice speed (Kyle: "writing it down is very slow", and no words while talking). Changes in `App/Voice.swift`:
passes now read only from the last settled sentence on (`clipTimestamps`), back to back, showing words as Whisper
writes them (progress callback); letting go waits for the running pass and reads only the tail. A log line per pass
("ShootDesk voice: pass ...", plus "model ready after N s" and "final text N s after letting go"). Measured in the
simulator before the change: 14.3 s from letting go to text, no words while talking; model loads in 14 s. After the
change, NOT measured: the simulator's mic didn't reliably hear the Mac's speaker, and the simulator runs the model on
the Mac's CPU (a phone uses the Neural Engine), so it's the worst case. Bug found on Kyle's iPhone and fixed: after
the download a late progress update set the state back to "Downloading voice 100%", so voice never became ready
(workaround: close and reopen the app). Set-up now shows "Getting voice ready…". Then, from Kyle's phone test: the live
text flipped to a jumbled agent list (Whisper's in-progress text includes the name hint), and the send waited on the
running pass. Fixed: the name hint is gone entirely (it also cost ~200 extra tokens per pass; Kyle: Whisper shouldn't
need it), and letting go stops the running pass (`Flag`, the callback returns false) before the final read. Installed
on Kyle's iPhone, not yet tried there. If still slow on the phone, consider a smaller/faster Whisper model (ask first).
On the phone the first "Getting voice ready" took minutes (iOS preparing the 626 MB model for the Neural Engine;
it may redo this after an app reinstall). Kyle (Oct 21): fine if it's a one-time wait; keep the large model. Option
if it bites: `openai_whisper-small.en_217MB` (much faster to prepare and run, a bit less accurate on names). `devicectl ... launch --console` restarts the app on
the phone each time; don't use it without asking Kyle.

## Oct 21: voice rebuilt once, on Apple's engine (Kyle: "awful, clunky"; asked for one researched change)

Research (WhisperKit paper, SpeechAnalyzer guides, hold-to-talk UX write-ups): Whisper isn't a streaming model, so
live words mean re-reading audio again and again; the 626 MB model was slow to prepare and to run. Kyle chose Apple's
on-device engine and tap-to-talk (he dislikes holding), auto-send after 2 s of quiet, and no captions.
- `App/Voice.swift`: `VoiceInput` + `LiveSession` on `SpeechAnalyzer` with `DictationTranscriber`
  (`.progressiveShortDictation`: live guesses, punctuation). Mic tap -> `AVAudioConverter` -> analyzer. Settled text
  plus a grey "guess"; loudness drives the waveform and the 2-second quiet timer. The old WhisperKit folder is deleted
  on launch (frees 606 MB). WhisperKit removed from `project.yml`; CLAUDE.md back to "no third-party packages".
- `Views/AskView.swift`: tap the mic -> `ListeningPanel` (pulsing red dot, "Listening", waveform, live words, X and
  send); haptic + sound on start. Removed "Hold to ask", "Let go to send…" and the download prompt; Settings > Ask is
  just the sounds switch.
- Measured on the Mac (Apple's engine fed a recorded 4-second question in real time, `say` + a test script): first
  word after 0.56 s, words kept pace, final punctuated text 0.05 s after stopping.
- The SIMULATOR CAN'T RUN IT: the dictation model shows "installed" but the engine offers no audio formats there
  (logged), so it fails with "No usable audio format". Kyle chose not to add a fallback engine. Installed on Kyle's
  iPhone Oct 21; not yet seen working there. Don't test voice by playing audio from the Mac (unreliable; Kyle asked).

## Oct 21: listening look like Siri (Kyle: "I don't like" the bars; voice itself works on his iPhone 16 Pro Max)

- `EdgeGlow` (AskView.swift): while listening, a soft glow in Claude's colors (coral, apricot, sand, clay) runs
  round the edge of the whole screen, slowly turning, thicker and brighter with your voice. On the NavigationStack, so
  the open Duo's title bar doesn't cover the top of it; ignores touches. Corner radius 54 (close to the iPhone's
  screen corners; the blur hides the rest).
- `VoiceOrb`: the talk button (now Claude coral, was the app blue) turns into a moving orb in the same spot; tap it
  to send sooner, X to cancel; the live words sit just above it. The red dot, "Listening" label and bars are gone.
- Both stop moving with Reduce Motion on.
- Seen in the simulator folded only (with a temporary fake-listening switch, removed before installing): glow hugs
  the screen edge and runs behind the tab pill; orb and words sit right. Open pose NOT checked (Kyle stopped the
  testing). Installed on Kyle's iPhone 16 Pro Max Oct 21; not yet seen there. Duo arrives Friday.

Not checked, and why:
- Filling in Book a shoot: the automatic safety check blocks automation from working the booking form (it's the
  screen that creates real orders). Try picking an agent, address, package and time by hand; never press Book it.
- Background refresh: still needs developer mode on the Mac (`DevToolsSecurity -status` says disabled; Kyle's
  password).
- Text fields (search, Ask's box, the booking address): automation can't type reliably; by hand.
- "Not needed" on the missing-deliverable flag: it changes Kyle's saved state, so left alone.
- Directions, Call, Text, On my way, Share, Save to Photos: they hand off to other apps or save files.
- Everything that needs the real phone (see "Not checked anywhere yet").

Not bugs, for the record: "Booked $0" for brand-new clients (Booked counts delivered orders, like the dashboard);
the black dot top right in the slideshow is the simulated camera hole; "Store" in the Listing kit is the town's
own classification; `shootdesk://shoot/<id>` needs Aryeo's long order id, not the order number.

Oct 19 setup notes:
- Kyle's Mac has three Xcodes. `/Applications/Xcode.app` is 27.0 and CANNOT build the app (no `onHingeChange` /
  `reservedRegions` in the 27.0 SDK). `~/Desktop/Xcode 2.app` and `~/Downloads/Xcode.app` are both 27.1 (27A9275,
  the same build GitHub used). Kyle switched the Mac's default to `~/Desktop/Xcode 2.app` with `xcode-select` on Oct 19.
- No Homebrew on the Mac. XcodeGen 2.46.0 (official GitHub release) is at `~/.local/xcodegen/xcodegen/bin/xcodegen`,
  not on PATH; run it by that full path from the project folder.
- Xcode 27 has no "Simulator" app; the simulator window is Device Hub
  (`<Xcode>/Contents/Applications/DeviceHub.app`), with Closed / Partially Open / Open buttons along the bottom.
- The Claude desktop app's iOS Simulator pane only lists the iOS 26.5 simulators, not the Duo, so it can't show
  the Duo. Use Device Hub; screenshots still work through the simulator tool.
- Simulator quirks seen: after a pose change, the simulator tool's screenshots go black or sideways until it's
  re-attached; in the Open pose its swipe directions are rotated 90°. Long-presses right after a scroll land on
  whatever scrolled under the finger, so wait a second first. `shootdesk://shoot/<order id>` opens a shoot page
  (asks "Open in ShootDesk?" the first time); it silently ignores excluded orders such as Jordan Rebello's.

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

## How building works now (Oct 19 2026): on the Mac

Kyle builds and runs the app on his Mac (Xcode 27.1, the iPhone Duo simulator); see "Build and run on the Mac" below.
From Oct 17 to Oct 19 a GitHub workflow (`.github/workflows/build.yml`) compiled every push on GitHub's cloud Macs
and took a screenshot of each tab. Kyle retired it on Oct 19 ("we're local") and the file was deleted, so a push now
only stores the code on GitHub. Left behind on purpose: the old `screenshots` branch on GitHub (untouched) and the
`-startTab <tab>` launch argument in `RootView` (nothing passes it now).

- Known warning, not an error: `App/Booking.swift:330`, Siri booking's `requestConfirmation(result:...)` is
  deprecated (Apple suggests `requestConfirmation(conditions:actionName:dialog:)`). Deprecated still works. Left
  alone on purpose: it's booking code and Siri booking hasn't been tried on a phone. Raise it, don't change it unasked.
- The GitHub repo IS public (checked Oct 17): anyone can read the code and these notes. No keys are in the repo
  (checked Oct 17); keep it that way.

## Build and run on the Mac (needs Xcode 27.1)

Start here (a local session in the Claude desktop app runs these itself; Kyle doesn't use Terminal):

    cd ~/Documents/ShootDesk-github && git pull && ~/.local/xcodegen/xcodegen/bin/xcodegen

(No Homebrew on this Mac; XcodeGen lives at that path, see the Oct 19 setup notes above. The Mac's default Xcode
must be the 27.1 one; check with `xcodebuild -version`.)

Then build and run on the iPhone Duo simulator (`xcodebuild ... -destination 'platform=iOS Simulator,id=1DBDC341-4076-48E1-9445-FC21C9F1AF1B'`;
there are two Duo simulators, so use the id. The desktop app's iOS Simulator pane can't show the Duo; Kyle watches in Device Hub). If `git pull` says local changes would be overwritten, stop and
read the message; don't force it. Oct 19 setup notes: Claude Code CLI 2.1.303 is installed at `~/.local/bin/claude`
(not on PATH unless Kyle added it); a cloud session can't control the Mac, a local desktop-app session can.

The Xcode project file isn't committed (see .gitignore); `project.yml` is the recipe. On a fresh clone, or whenever
source files are added or removed, run `xcodegen` in the project folder first.
Then put your Apple Team ID in `project.yml` under DEVELOPMENT_TEAM if Xcode asks for signing.

    cd ~/Documents/ShootDesk-github
    xcrun simctl list devices available | grep -i duo        # find the iPhone Duo simulator's name/UDID
    xcodebuild -project ShootDesk.xcodeproj -scheme ShootDesk \
      -destination 'platform=iOS Simulator,name=iPhone Duo' build 2>&1 | tail -40
    xcrun simctl boot 1DBDC341-4076-48E1-9445-FC21C9F1AF1B; open "$(xcode-select -p)/../Applications/DeviceHub.app"
    # install + launch the built app (path printed by xcodebuild, under DerivedData .../Build/Products/Debug-iphonesimulator/ShootDesk.app)
    xcrun simctl install booted <path to ShootDesk.app>
    xcrun simctl launch booted com.horizonhomemedia.shootdesk
    xcrun simctl io booted screenshot ~/Desktop/shootdesk-check.png

Folding: no `simctl` command found for it. Device Hub's Closed / Partially Open / Open buttons work, and a local
session with computer use can press them itself (verified Oct 19).

## Verify, in this order (take a screenshot for each)

Oct 19 status: 0 retired; 1–3 and 6 done (see "Oct 19 Mac session: verify results" and "Oct 19 full simulator pass" above); 4 waits on developer mode;
5 fixed in the simulator Oct 19 (shoot page was black when half-open; now shows the normal page); 7 is this update (README status not yet updated).

0. Retired Oct 19 with the GitHub build (was: look at the cloud screenshots of every tab; done Oct 17, all fine).
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
5. Half-open pose: Partially Open → shoot page: the normal page (the simulated Duo folds like a book). A fold that
   runs side to side would show the photo above it and the details below.
6. Haptics can't be felt in the simulator — "simulated, not checked on a real phone".
7. Update the Status section of `README.md` and this file. Keep `CLAUDE.md` "Known quirks" current.

## The HTML demo (Oct 19 2026): `Demo/ShootDeskDuoDemo.html`

Kyle asked for "a working demo in HTML that runs an iPhone Duo" to show people. It is a clickable replica of the
app inside a drawn Duo, not the app: Closed / Half-open / Open poses, light and dark, every tab, the shoot page, agent
pages, Book a shoot, Open times, Schedule, the Upcoming check page, the photo gallery and slideshow, Ask with canned
answers that type out. Published privately at https://claude.ai/artifact/S9CCMk9LHUPk9yraNB8SjL (Kyle shares it from
the page's Share menu); the same file is in the repo and opens in any browser.
- Built from the Swift screens, not from memory: nine readers extracted each screen's exact copy, layout rules and
  folded/open differences (the specs are not in the repo; redo the read if you rebuild). Layout rules it follows:
  18/28 gutters, serif addresses, rails that stop at the tab pill, two columns when open, photo above the hinge in
  the half-open pose, the 30-minute driving pad in Open times and Book a shoot, the agent "usually books" sentence.
- Everything in it is made up: fictional agents (Dana Oliveira, Marcus Bell, ...), invented house numbers on real
  South Coast road names, drawn house "photos" (canvas, no real listings), Stripe-shaped numbers. No keys, no network.
  Keep it that way; it is public once shared.
- Known differences from the app, on purpose: no map tiles (a drawn stand-in with the app's town bubbles and merge
  rule; a tap on a merged bubble zooms instead of fitting the camera), the open-pose Ask sidebar is 270pt wide (the
  app's 360 leaves no room on a 626pt screen once the pill is counted), Directions / Call / Text / Aryeo show a note
  instead of leaving the page, sunset is computed for Dartmouth in the viewer's own time zone (right for Kyle, off
  elsewhere), and the "today" demo shoots move to tomorrow after 3 PM so the Today tab always has a next shoot.
- Checked Oct 19 in the sandbox's Chromium (28 screenshots, no console errors, no sideways scroll at phone width).
  Not checked in Safari or on a phone. The page follows the viewer's light/dark setting; the app inside has its own
  switch (the page's "Match page / Light / Dark" and Settings → Appearance are the same control).
- To change it: the source is the single HTML file (styles, then markup, then four script blocks: helpers and data,
  screens, more screens, the shell). Republish with the Artifact tool using the same file path to keep the link.

## Security rules (do not bend these)

- Keys (Aryeo, Claude, Stripe restricted key) are typed by Kyle into Settings and live only in the Keychain.
  Never write a key into a file, a log, a commit or source. Never type a real key into the app for him.
- The only code that writes to Aryeo is booking (`App/Booking.swift`), after Kyle confirms, with `notify: true`.
  In testing never press the final "Book it": it creates a real order and emails a real agent.
- Reminders Kyle still owes himself: delete Aryeo test order #1857; rotate the Aryeo API key and the Stripe
  secret key that were exposed earlier. Remind him once per session until done.
- `Rules` in `Core/Domain.swift` match his business dashboard; don't change them without asking.

## Not checked anywhere yet

(The app now runs on Kyle's regular iPhone, see "Where things stand", but none of these have been tried there yet.)
Siri, widgets, notifications, the Live Activity, quick actions, haptics and real drive times on a real phone;
typing an address into Book a shoot (the simulator wouldn't take typing from automation); an actual booking.

## Parked ideas (Kyle has NOT asked for these; raise, don't build)

- TABLED Oct 21 by Kyle ("probably unneeded for now"): real push notifications. Today every alert (leave now,
  7 AM briefing, missing video/floor plan) and the Lock Screen countdown are scheduled on the phone when the app
  runs, so a booking made in Aryeo while the app is closed isn't announced until the next refresh. True push would
  need a small always-on server (Aryeo webhook -> Apple's push service).

- PARKED Oct 20 at Kyle's request: add and delete listing photos from the app, the way Aryeo Go does. Checked Oct 20:
  Aryeo's public API (docs.aryeo.com/api/aryeo, and their Go SDK) has no endpoint to upload, delete or reorder
  listing images; it can only read them (it can update and delete videos). Aryeo Go uses Aryeo's private API.
  Options raised: ask Aryeo support for API access (Claude can draft the email), or a button that opens the
  listing's photos in Aryeo Go. Don't reverse-engineer the private API.

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
  asked for and built Oct 17 and retired Oct 19; see "How building works now".)
- Kyle asked Oct 17 to "show every page screenshots". The cloud tour (empty states on a regular iPhone) was
  retired Oct 19; real pages with his shoots, on the Duo, folded and open, come from the Duo simulator on the Mac.
