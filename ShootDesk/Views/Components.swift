import SwiftUI
import MapKit

// MARK: - Design system
//
// "Cinema for listings": the photos and the addresses lead, the chrome stays quiet.
// Addresses and key numbers are set in New York (Apple's serif); everything else in SF Pro.
// One accent (Horizon azure). Content is laid out once and grows when the Duo is opened.

extension Font {
    /// Addresses and names: Apple's serif, like a printed listing sheet.
    static func address(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    static func address(_ style: Font.TextStyle, weight: Font.Weight = .semibold) -> Font {
        .system(style, design: .serif, weight: weight)
    }
}

/// Side margin: a little more room when the Duo is open.
struct Gutter {
    static func of(_ size: UserInterfaceSizeClass?) -> CGFloat { size == .regular ? 28 : 18 }
    /// Room for a side column next to the main content (Ask's question list, Settings' second column).
    /// The open Duo held wide is about 950 points; held tall it's about 670, which is too narrow for one.
    static let sideColumnWidth: CGFloat = 820
}

/// The search field at the top of Listings and Customers. It sits on the same side margin as the page
/// under it (the system search bar uses its own margins, which didn't line up on the Duo).
struct SearchBox: View {
    @Environment(\.horizontalSizeClass) private var size
    @Binding var text: String
    let prompt: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .focused($focused)
                .submitLabel(.search)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Color(.tertiarySystemFill), in: Capsule())
        .padding(.horizontal, Gutter.of(size))
        .padding(.top, 6)
        .padding(.bottom, 4)
        .background(Color(.systemBackground))
    }
}

/// Cards and tiles shrink a touch while pressed, so taps feel physical.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
}

/// The main action on a screen: filled azure capsule.
struct PrimaryActionStyle: ButtonStyle {
    var prominent = true
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(prominent ? Color.white : Theme.accent)
            .background(prominent ? Theme.accent : Theme.accent.opacity(0.14), in: Capsule())
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

/// Section title with an optional quiet note and an optional trailing action.
struct SectionHeader: View {
    let title: String
    var note: String? = nil
    var action: (title: String, run: () -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.title3.weight(.bold))
            if let note { Text(note).font(.subheadline).foregroundStyle(.secondary) }
            Spacer(minLength: 8)
            if let action {
                Button(action.title, action: action.run)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
    }
}

// MARK: - Horizontal scrollers and the Duo's side tab bar

/// On the iPhone Duo, iOS 27 puts the tab bar in a vertical pill down the right edge and counts the strip
/// under it as "safe area". Horizontal scrollers ignore the safe area along the way they scroll (that's how
/// they run under a notch), so left alone their cards run on underneath the pill: that was the broken look
/// on the folded Listings tab. This scroller measures how much of its width is clear of the pill and cuts
/// itself off there. On a phone with no side bar it measures nothing and behaves like a plain ScrollView.
struct SideSafeScroller<Content: View>: View {
    /// Snap card by card (needs `.scrollTargetLayout()` on the content).
    var aligned = false
    @ViewBuilder let content: () -> Content
    @State private var clearWidth: CGFloat?

    private struct Reading: Equatable { var width: CGFloat; var inset: CGFloat }

    var body: some View {
        VStack(spacing: 0) {
            // A zero-height ruler. It stays inside the safe area (only scrollers extend), so its width is
            // exactly the room clear of the pill, and its trailing inset says whether there is a pill at all.
            Color.clear
                .frame(height: 0)
                .onGeometryChange(for: Reading.self) {
                    Reading(width: $0.size.width, inset: $0.safeAreaInsets.trailing)
                } action: { r in
                    clearWidth = r.inset > 0.5 ? r.width : nil
                }
            scroller
                // The scroller's frame runs on under the pill; this masks off everything past the ruler's width.
                .mask(alignment: .leading) { Rectangle().frame(width: clearWidth) }
        }
    }

    @ViewBuilder private var scroller: some View {
        if aligned {
            ScrollView(.horizontal, showsIndicators: false) { content() }
                .scrollTargetBehavior(.viewAligned)
        } else {
            ScrollView(.horizontal, showsIndicators: false) { content() }
        }
    }
}

/// A horizontal row of cards you swipe through, snapping card by card.
struct Rail<Item: Identifiable, CardView: View>: View {
    let title: String
    var note: String? = nil
    let items: [Item]
    var cardWidth: CGFloat = 260
    @ViewBuilder let card: (Item) -> CardView
    @Environment(\.horizontalSizeClass) private var size

    var body: some View {
        let gutter = Gutter.of(size)
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: title, note: note).padding(.horizontal, gutter)
            SideSafeScroller(aligned: true) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(items) { item in
                        card(item).frame(width: cardWidth)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, gutter)
            }
        }
    }
}

// MARK: - Big sheets

/// A sheet on the folded phone; the whole screen on the open Duo, so forms get the room to spread out.
struct AdaptiveSheet<Sheet: View>: ViewModifier {
    @Binding var isPresented: Bool
    @ViewBuilder let sheet: () -> Sheet
    @Environment(\.horizontalSizeClass) private var size

    func body(content: Content) -> some View {
        if size == .regular {
            content.fullScreenCover(isPresented: $isPresented, content: sheet)
        } else {
            content.sheet(isPresented: $isPresented, content: sheet)
        }
    }
}

extension View {
    func adaptiveSheet<Sheet: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Sheet) -> some View {
        modifier(AdaptiveSheet(isPresented: isPresented, sheet: content))
    }
}

// MARK: - Zoom transition (card zooms into its page on iOS 18+)

extension View {
    @ViewBuilder func zoomSource(_ id: String, in ns: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) { self.matchedTransitionSource(id: id, in: ns) } else { self }
    }
    @ViewBuilder func zoomDestination(_ id: String, in ns: Namespace.ID?) -> some View {
        if #available(iOS 18.0, *), let ns { self.navigationTransition(.zoom(sourceID: id, in: ns)) } else { self }
    }
}

// MARK: - iPhone Duo fold (iOS 27.1+)

/// Tells a screen when the Duo is sitting half-open, hinge partly folded like a laptop, so it can put the
/// picture on the top half and the controls on the bottom. Older systems (and the folded or flat Duo) report false.
struct FoldWatch: ViewModifier {
    @Binding var halfOpen: Bool

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.onHingeChange { _, context in
                halfOpen = context.hinge?.status == .partiallyOpen
            }
        } else {
            content
        }
    }
}

extension View {
    func foldWatch(halfOpen: Binding<Bool>) -> some View { modifier(FoldWatch(halfOpen: halfOpen)) }
}

extension GeometryProxy {
    /// Where the fold crosses this view while the Duo is half-open: the top and bottom of the hinge band,
    /// in this view's own coordinates. Nil when the phone is flat, closed, or isn't a Duo.
    var foldBand: (top: CGFloat, bottom: CGFloat)? {
        if #available(iOS 27.1, *) {
            if let fold = reservedRegions(kind: .division).first(where: { $0.isActive }) {
                return (fold.frame.minY, fold.frame.maxY)
            }
        }
        return nil
    }

    /// True when the fold runs top to bottom through this view (the Duo standing like a half-open book),
    /// where a picture-above, details-below split doesn't fit. False when flat, closed, or not a Duo.
    var foldRunsTopToBottom: Bool {
        if #available(iOS 27.1, *) {
            if let fold = reservedRegions(kind: .division).first(where: { $0.isActive }) {
                return fold.frame.height > fold.frame.width
            }
        }
        return false
    }
}

// MARK: - Status

struct StatusChip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.16), in: Capsule())
    }
}

extension JobStatus {
    var color: Color {
        switch self {
        case .booked: return Theme.accent
        case .editing: return .secondary
        case .delivered: return .green
        case .unscheduled: return Theme.accent
        case .stale: return .secondary
        }
    }
}

// MARK: - Photos

/// A remote photo, kept in memory once loaded so scrolling back never flickers.
struct RemotePhoto: View {
    let url: URL?
    var cornerRadius: CGFloat = 10

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Rectangle()
            .fill(Color(.secondarySystemFill))
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .transition(.opacity)
                } else if failed || url == nil {
                    Image(systemName: url == nil ? "house" : "photo").foregroundStyle(.tertiary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .task(id: url) {
                guard let url else { return }
                if let hit = ImageCache.shared.cached(url) { image = hit; return }
                let loaded = await ImageCache.shared.load(url)
                withAnimation(.easeOut(duration: 0.25)) {
                    image = loaded
                    failed = loaded == nil
                }
            }
    }
}

/// Artwork for a shoot that has no photos yet: the date, big, on an azure wash.
struct DateArt: View {
    let date: Date?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [Theme.accent.opacity(0.85), Theme.accent.opacity(0.35)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "camera.aperture")
                .font(.system(size: 120, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.10))
                .offset(x: 90, y: -30)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            VStack(alignment: .leading, spacing: 0) {
                Text(date.map { FieldTime.format($0, "EEEE") } ?? "Date to be set")
                    .font(.subheadline.weight(.semibold))
                Text(date.map { FieldTime.format($0, "d") } ?? "–")
                    .font(.address(46))
                Text(date.map { FieldTime.format($0, "MMMM") } ?? "")
                    .font(.caption.weight(.medium))
                    .opacity(0.85)
            }
            .foregroundStyle(.white)
            .padding(14)
        }
        .clipped()
    }
}

/// Date tile for shoots without photos (small square version for list rows).
struct DateTile: View {
    let date: Date?
    var size: CGFloat = 46

    var body: some View {
        VStack(spacing: 0) {
            Text(date.map { FieldTime.format($0, "MMM") } ?? "TBD")
                .font(.system(size: size * 0.22, weight: .bold))
                .foregroundStyle(Theme.accent)
            Text(date.map { FieldTime.format($0, "d") } ?? "–")
                .font(.system(size: size * 0.42, weight: .semibold, design: .serif))
        }
        .frame(width: size, height: size)
        .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }
}

struct JobThumb: View {
    let job: Job
    var size: CGFloat = 46

    var body: some View {
        Group {
            if let url = job.thumbURL {
                RemotePhoto(url: url, cornerRadius: size * 0.24)
            } else {
                DateTile(date: job.start, size: size)
            }
        }
        .frame(width: size, height: size)
    }
}

/// The one card used everywhere a shoot appears: artwork on top (the cover photo, or the date when
/// there are no photos yet), the address in serif, then town and agent.
struct ShootCard: View {
    let job: Job
    var flag: DeliveryFlag? = nil
    /// Show the shoot time over the artwork (upcoming shoots).
    var showsTime = false
    /// Leave the agent off (on that agent's own page).
    var showsAgent = true

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // A fixed 16:10 box the column's width, with the artwork filling it. (Putting the aspect ratio
            // on the artwork itself let the date art, which stretches to any size offered, spill past its
            // column and make the whole grid row taller and wider than the others.)
            Color.clear
                .aspectRatio(16 / 10, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay {
                    if let url = job.heroURL { RemotePhoto(url: url, cornerRadius: 0) }
                    else { DateArt(date: job.start) }
                }
                .overlay(alignment: .topTrailing) {
                    if showsTime, let s = job.start {
                        Text(FieldTime.clockAMPM(s))
                            .font(.caption.weight(.semibold)).monospacedDigit()
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(8)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(job.street).font(.address(.headline)).lineLimit(1)
                if let flag {
                    Label(flag.line, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.medium)).foregroundStyle(.orange).lineLimit(1)
                } else {
                    (Text(job.town.isEmpty ? "" : job.town + "   ") + Text(showsAgent ? job.agentName : "").foregroundStyle(.tertiary))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Cards

struct Card<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title = title {
                Text(title)
                    .font(.headline)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).foregroundStyle(valueColor).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

/// Text panel floating over a photo, Apple-Maps style.
struct GlassCaption<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 2) { content }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct MissingKeyView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Connect Aryeo", systemImage: "key")
        } description: {
            Text("Open Settings and paste your Aryeo API key. The app reads your schedule, listings and customers straight from Aryeo.")
        }
    }
}

/// Initials in a circle, tinted per person so the list is easy to scan.
struct Monogram: View {
    let name: String
    let initials: String
    var size: CGFloat = 40

    private var tint: Color {
        let palette: [Color] = [.blue, .teal, .indigo, .purple, .pink, .orange, .green, .cyan]
        let h = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return palette[h % palette.count]
    }

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.16), in: Circle())
    }
}

// MARK: - Week strip

struct WeekStrip: View {
    @Binding var selected: Date
    let count: (Date) -> Int

    private var days: [Date] {
        let cal = FieldTime.calendar
        let start = cal.dateInterval(of: .weekOfYear, for: selected)?.start ?? FieldTime.startOfDay(selected)
        return (0..<7).map { FieldTime.addDays($0, to: start) }
    }

    var body: some View {
        HStack(spacing: 0) {
            Button { withAnimation(.snappy) { selected = FieldTime.addDays(-7, to: selected) } } label: {
                Image(systemName: "chevron.left").frame(width: 32, height: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Previous week")
            ForEach(days, id: \.self) { day in
                let isSel = FieldTime.isSameDay(day, selected)
                let isToday = FieldTime.isSameDay(day, Date())
                let n = count(day)
                Button { withAnimation(.snappy) { selected = day } } label: {
                    VStack(spacing: 3) {
                        Text(FieldTime.format(day, "EEEEE"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(isToday ? Theme.accent : Color.secondary)
                        Text(FieldTime.format(day, "d"))
                            .font(.body.weight(isSel ? .bold : .regular))
                            .foregroundStyle(isSel ? Color.white : Color.primary)
                            .frame(width: 34, height: 34)
                            .background(isSel ? Theme.accent : Color.clear, in: Circle())
                        Circle().fill(n > 0 ? Theme.accent.opacity(isSel ? 0 : 0.8) : .clear).frame(width: 5, height: 5)
                    }
                    .frame(maxWidth: .infinity, minHeight: 58)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(FieldTime.format(day, "EEEE MMMM d")), \(n) shoot\(n == 1 ? "" : "s")")
            }
            Button { withAnimation(.snappy) { selected = FieldTime.addDays(7, to: selected) } } label: {
                Image(systemName: "chevron.right").frame(width: 32, height: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Next week")
        }
    }
}

// MARK: - Map (Apple Maps: built into iOS, no key or fee)

struct MapPin: Identifiable, Hashable {
    let id: String
    let label: String
    let title: String
    let lat: Double
    let lon: Double
    let highlighted: Bool
}

struct ShootMap: View {
    let pins: [MapPin]
    var onSelect: (String) -> Void = { _ in }
    @State private var position: MapCameraPosition

    init(pins: [MapPin], onSelect: @escaping (String) -> Void = { _ in }) {
        self.pins = pins
        self.onSelect = onSelect
        _position = State(initialValue: Self.camera(for: pins))
    }

    /// One house: street level, so you can see the neighbourhood (not a close-up of rooftops).
    /// Several: fit them all.
    static func camera(for pins: [MapPin]) -> MapCameraPosition {
        if pins.count == 1, let p = pins.first {
            return .camera(MapCamera(centerCoordinate: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon),
                                     distance: 2200, heading: 0, pitch: 0))
        }
        return .automatic
    }

    var body: some View {
        Map(position: $position) {
            ForEach(pins) { p in
                Annotation(p.title, coordinate: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon)) {
                    Group {
                        if p.label.isEmpty {
                            Image(systemName: "camera.fill").font(.caption.weight(.bold))
                        } else {
                            Text(p.label).font(.caption.weight(.bold))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(width: p.highlighted ? 32 : 26, height: p.highlighted ? 32 : 26)
                    .background(p.highlighted ? Theme.accent : Color(.darkGray), in: Circle())
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                    .onTapGesture { onSelect(p.id) }
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        // Moving to another day (or another shoot) moves the map with it.
        .onChange(of: pins.map(\.id)) { _, _ in
            withAnimation(.smooth) { position = Self.camera(for: pins) }
        }
    }
}

// MARK: - Opening other apps

enum Launcher {
    static func directions(to job: Job) {
        directions(lat: job.latitude, lon: job.longitude, address: job.address?.unparsedAddress)
    }

    static func directions(lat: Double?, lon: Double?, address: String?) {
        if let app = Directions.googleMapsAppURL(lat: lat, lon: lon, address: address),
           UIApplication.shared.canOpenURL(app) {
            UIApplication.shared.open(app)
        } else if let web = Directions.googleMapsWebURL(lat: lat, lon: lon, address: address) {
            UIApplication.shared.open(web)
        }
    }

    static func open(_ url: URL?) {
        guard let url = url else { return }
        UIApplication.shared.open(url)
    }
}

/// Claude's spark (the official mark, from claude.ai), shown on anything Claude writes: Ask and the Listing kit.
struct ClaudeMark: View {
    var size: CGFloat = 18
    /// Draw it in one colour (white on a blue button) instead of Claude's orange.
    var tint: Color? = nil
    var body: some View {
        Image("ClaudeSpark")
            .resizable()
            .renderingMode(tint == nil ? .original : .template)
            .foregroundStyle(tint ?? .primary)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityLabel("Claude")
    }
}

/// Claude's colour, for the few touches that go with its mark.
extension Color {
    static let claude = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
}

/// A brand mark in the title bar (Stripe on Money, Claude on Ask). iOS 26 and later put a glass bubble behind
/// every title-bar item; a logo looks boxed in with one, so this leaves it off.
struct TitleBarMark<Content: View>: ToolbarContent {
    @ViewBuilder var content: () -> Content
    var body: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .topBarTrailing) { content() }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarTrailing) { content() }
        }
    }
}

/// Stripe's wordmark, shown next to anything that comes from Stripe.
struct StripeMark: View {
    var height: CGFloat = 14
    var body: some View {
        Image("StripeLogo")
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .accessibilityLabel("Stripe")
    }
}
