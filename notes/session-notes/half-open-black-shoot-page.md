# Half-open shoot page goes black: cause VERIFIED (Oct 19, simulator only)

Duo sim 1DBDC341, Device Hub Partially Open pose, shoot page for 6 Morrison Way (opened from the Today card).
Temporary NSLog in StopDetailView.laptop, read via `log stream`, since removed (git clean, rebuilt + reinstalled
without it; `strings` on the dylib finds no FOLDDEBUG).

Logged once:
- geo.size = 867 x 635 (screen is ~951 x 669 pt; 84 pt trailing safe area = tab pill, 34 pt bottom)
- safe area: top 0, leading 0, bottom 34, trailing 84
- reservedRegions(kind: .division) = one region, active, frame x 455.5, y 0, w 40, h 669
- foldBand = (top: 0, bottom: 669)

So the hinge is a 40 pt VERTICAL strip down the middle (book fold). `laptop` reads only minY/maxY:
photo height 0, spacer height 669 (taller than the 635 view, painted systemBackground = black in dark mode),
details height max(0, 635 - 669) = 0. Exactly the guess in HANDOFF step 5.

Side note: the region's frame runs 0..669 (full screen height) while the view is 635 tall, so the band
isn't strictly in the view's own coordinates near the bottom edge; matters only for a horizontal fold.

Kyle chose option B (normal page when the fold runs top to bottom). Done, uncommitted: GeometryProxy.foldRunsTopToBottom in Components.swift, StopDetailView.laptop shows `page` when true; HANDOFF step 5 updated. Checked in the Partially Open pose only.
