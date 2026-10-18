# ShootDesk: Horizon Home Media's own app

A personal iPhone app that replaces Aryeo Go, built for the iPhone Duo. Folded, every screen is one clean column. Open, the same screen spreads out to use the whole display.

It reads live from Aryeo and Stripe. It only writes to Aryeo in one place: booking a shoot (from Siri or the Book a shoot screen), and only after you confirm.

## Tabs

| Tab | What it does |
|---|---|
| **Today** | Your next shoot big (photo or map), leave-by time, Directions and Text buttons, any warnings, then rows for missing deliverables, this week and recently delivered. Buttons at the top: **+** (book a shoot), **Open times**, **Schedule**. |
| **Listings** | Upcoming shoots and every past shoot as a photo gallery, with search. The map button shows **every shoot you've done on a map**: a bubble per town sized by shoot count, merged when they'd overlap, zoom in to see each house. Tap a town for its card. |
| **Customers** | Every agent. Folded: a list. Open: a sortable table. Agent pages: call/text/email, booking rhythm ("usually books about every 3 weeks"), orders by month chart, top towns, every shoot, every order, and Book a shoot. |
| **Money** | Live from Stripe: received this month vs the same days last year, available and on the way, month-by-month chart vs last year, year-end pace, fees, who paid you most this year, every payment (matched to its listing) and every payout. |
| **Ask** | Plain-English questions answered by Claude from your Aryeo orders and Stripe totals. Answers type out as they arrive. |
| **Settings** | Appearance, the three keys (Aryeo, Claude, Stripe restricted key), re-download, test Claude. |

**Shoot page** (every card opens it): full-bleed photo or map, Directions / Call / On my way / Aryeo, the order, the agent, light and weather, notes, videos, photos, floor plans, **Present listing**, Save all, Listing kit, and **This house before** when you've shot the address on another order.

**Present listing** (a pitch tool): opening card with the address over the hero photo, then the videos, then each photo full screen with a slow drift and soft crossfades. Tap to stop and browse.

**Open times**: the next 7 days from 8 AM to sunset, with 30 minutes kept clear around each shoot. Pick openings and send an agent a ready-made text.

**Book a shoot**: agent (shorthand works), address (shorthand works, Apple Maps finds it), package (live from Aryeo), and only start times that fit. Checks Aryeo for clashes, then asks "Book it?" Aryeo emails the agent its usual confirmation.

**Upcoming check** (the orange bar on Today): the rest of today plus the next two days, checked for rain, wind on drone shoots, New Bedford airspace, bad agent emails and sunset, with a suggested better day.

**Missing deliverables**: two or more days after a shoot, if the order includes video or a floor plan that isn't delivered in Aryeo (and the photos are), it's flagged. "Not needed" clears it.

## Beyond the app

- **Siri**: "What do I have tomorrow?", "When am I open Monday?", "Book Tiffany Monday at 3 for Essentials Plus at 9 Radcliffe Ln", next shoot, directions, text the agent, agent stats, and open any shoot.
- **Lock Screen Live Activity**: from 3 hours before you need to leave until the shoot starts: the street, "Leave by 10:06 AM", a live countdown and the drive time.
- **Leave-by alerts**: a notification when it's time to go, using Apple Maps drive time with traffic.
- **Widgets**: Next Shoot (Home Screen and Lock Screen sizes) and Evening Check.
- **Quick actions**: press and hold the app icon for Book a shoot, Open times, and your next shoot.

## Keys (stored only in the phone's keychain)

- **Aryeo** (required): Aryeo admin, developer/API settings.
- **Claude** (Ask, Listing kit, drafted texts): platform.claude.com.
- **Stripe** (Money): a *restricted* key with Read on Balance, Balance transactions and Payouts. It can't move money.

## Building

Open `ShootDesk.xcodeproj` in Xcode 27.1, pick the iPhone Duo (simulator or your phone) and press Run. If you add files, run `xcodegen` first. `CLAUDE.md` has the details for Claude Code.

## Status (honest version, Oct 16 2026)

- **Checked in the iPhone Duo simulator (folded and open, light and dark):** every tab and the main pages, the shoot map, Present mode, Open times, Book a shoot up to the final confirm, the Live Activity appearing and disappearing, live Stripe numbers, Ask with Stripe data.
- **Not checked on a real phone yet:** Siri, widgets, notifications, the Live Activity, quick actions (press and hold), haptics, real-world maps and drive times.
- **Not checked at all:** typing an address into Book a shoot (the simulator wouldn't take typing from automation), and an actual booking from the new screen (that would create a real order).
- **Since Oct 17:** every push is compiled on GitHub's cloud Mac and opened there on a regular iPhone simulator (iOS 27.0; the Duo simulator isn't on GitHub's Macs yet), every tab in light and dark, with the screenshots on the `screenshots` branch. That proves the code compiles and the app starts, nothing more; the Oct 17 changes haven't been seen working anywhere.
