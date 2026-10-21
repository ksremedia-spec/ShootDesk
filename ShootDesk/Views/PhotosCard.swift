import SwiftUI
import Photos
import AVKit

/// Everything delivered for a listing: videos, photos and floor plans.
/// Tap any one to view it full screen; "Present listing" plays the whole thing as a slideshow.
struct PhotosCard: View {
    @Environment(AppModel.self) private var model
    let job: Job
    /// The cover photo's id, passed in so the grid redraws when it changes (a job with a new cover
    /// still compares equal, so SwiftUI would otherwise keep the old "Cover" label).
    let coverID: String?
    var onKit: (() -> Void)? = nil

    @State private var saver = PhotoSaver()
    @State private var showAll = false
    @State private var gallery: GalleryRequest?
    @Environment(\.horizontalSizeClass) private var size

    private var wide: Bool { size == .regular }
    private var listingID: String? { job.order.listing?.id }
    private var media: ListingMedia? { listingID.flatMap { model.media[$0] } }
    private var images: [ListingImage] {
        if let m = media, !m.images.isEmpty { return m.images }
        return job.images
    }
    private var videos: [ListingVideo] { media?.videos ?? [] }
    private var plans: [FloorPlan] { media?.floorPlans ?? [] }
    private var isLoading: Bool { listingID.map { model.mediaLoading.contains($0) } ?? false }
    private var previewCount: Int { wide ? 15 : 12 }
    private var preview: [ListingImage] { Array(images.prefix(showAll ? images.count : previewCount)) }

    /// Everything in viewing order: videos, then photos, then floor plans.
    private var allItems: [MediaItem] {
        videos.map(MediaItem.video) + images.map(MediaItem.photo) + plans.map(MediaItem.plan)
    }

    private func open(_ item: MediaItem, present: Bool = false) {
        let items = allItems
        gallery = GalleryRequest(items: items, start: items.firstIndex(of: item) ?? 0, present: present,
                                 title: job.street, subtitle: job.townState, cover: job.heroURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            if !allItems.isEmpty {
                // Pitch mode: the whole listing, full screen, as a slideshow.
                Button { if let first = allItems.first { open(first, present: true) } } label: {
                    Label("Present listing", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryActionStyle())
            }
            if !videos.isEmpty { videoSection }
            if !images.isEmpty { photoSection }
            if !plans.isEmpty { planSection }
            if isLoading && allItems.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Looking for photos, video and floor plans…").font(.footnote).foregroundStyle(.secondary)
                }
            } else if allItems.isEmpty && (job.status == .delivered || job.status == .editing) {
                Text("Nothing delivered in Aryeo yet.").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .task(id: job.id) { await model.loadMedia(for: job) }
        .fullScreenCover(item: $gallery) { GalleryViewer(request: $0) }
    }

    // MARK: Videos

    private var videoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: videos.count == 1 ? "Video" : "Videos", note: videos.count > 1 ? "\(videos.count)" : nil)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: wide ? 320 : 260), spacing: 14)], spacing: 14) {
                ForEach(videos) { v in
                    Button { open(.video(v)) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            ZStack {
                                RemotePhoto(url: URL(string: v.thumbnailUrl ?? ""), cornerRadius: 0)
                                    .aspectRatio(16 / 9, contentMode: .fill)
                                Color.black.opacity(0.18)
                                Image(systemName: "play.fill")
                                    .font(.title2)
                                    .foregroundStyle(.white)
                                    .frame(width: 58, height: 58)
                                    .background(.ultraThinMaterial, in: Circle())
                            }
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            HStack {
                                Text(Self.cleanTitle(v.title)).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Spacer()
                                if let d = v.durationLabel { Text(d).font(.subheadline).foregroundStyle(.secondary).monospacedDigit() }
                            }
                        }
                    }
                    .buttonStyle(.pressable)
                }
            }
        }
    }

    /// Aryeo names videos "Video #1 - 28 Erin Ct, New Bedford, MA 02745"; the address is already on screen.
    /// "Floorplan #3" → "Floor plan 3"
    static func planTitle(_ raw: String?) -> String {
        guard let t = raw?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return "Floor plan" }
        return t.replacingOccurrences(of: "Floorplan", with: "Floor plan", options: .caseInsensitive)
            .replacingOccurrences(of: "#", with: "")
    }

    static func cleanTitle(_ raw: String?) -> String {
        guard var t = raw?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return "Video" }
        if let dash = t.range(of: " - ") { t = String(t[..<dash.lowerBound]) }
        return t.replacingOccurrences(of: "#", with: "")
    }

    // MARK: Photos

    private var photoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Photos", note: "\(images.count)")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: wide ? 150 : 104), spacing: 4)], spacing: 4) {
                ForEach(preview, id: \.stableID) { img in
                    let isCover = img.stableID == coverID
                    Button { open(.photo(img)) } label: {
                        Color.clear
                            .aspectRatio(4 / 3, contentMode: .fit)
                            .overlay { RemotePhoto(url: URL(string: img.thumbnailUrl ?? img.largeUrl ?? ""), cornerRadius: 0) }
                            .overlay(alignment: .bottomLeading) {
                                if isCover {
                                    Text("Cover")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 7).padding(.vertical, 3)
                                        .background(.ultraThinMaterial, in: Capsule())
                                        .padding(5)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.pressable)
                    // Press and hold a photo to make it the one on the card.
                    .contextMenu {
                        if isCover, CoverChoice.imageID(for: job.id) != nil {
                            Button { withAnimation(.snappy) { model.setCover(nil, for: job) } } label: {
                                Label("Use Aryeo's first photo", systemImage: "arrow.uturn.backward")
                            }
                        } else if !isCover {
                            Button { withAnimation(.snappy) { model.setCover(img, for: job) } } label: {
                                Label("Use as cover photo", systemImage: "photo.badge.checkmark")
                            }
                        }
                        Button { open(.photo(img)) } label: { Label("View", systemImage: "arrow.up.left.and.arrow.down.right") }
                    }
                }
            }
            if images.count > previewCount {
                Button(showAll ? "Show fewer" : "Show all \(images.count)") { withAnimation(.snappy) { showAll.toggle() } }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }

            HStack(spacing: 10) {
                Button { Task { await saver.save(images, title: job.street, transfers: model.transfers) } } label: {
                    Label(saver.state.label(total: images.count), systemImage: saver.state.icon)
                }
                .buttonStyle(PrimaryActionStyle(prominent: false))
                .disabled(saver.state.isBusy)

                if let onKit = onKit, job.status == .delivered || job.status == .editing {
                    Button(action: onKit) { Label { Text("Listing kit") } icon: { ClaudeMark(size: 17) } }
                        .buttonStyle(PrimaryActionStyle(prominent: false))
                }
            }
            if case .saving(let done) = saver.state {
                ProgressView(value: Double(done), total: Double(max(images.count, 1))).tint(Theme.accent)
            }
            if case .failed(let why) = saver.state {
                Text(why).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    // MARK: Floor plans

    private var planSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: plans.count == 1 ? "Floor plan" : "Floor plans", note: plans.count > 1 ? "\(plans.count)" : nil)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: wide ? 220 : 150), spacing: 12)], spacing: 12) {
                ForEach(plans) { plan in
                    Button { open(.plan(plan)) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            FittedImage(url: URL(string: plan.largeUrl ?? plan.thumbnailUrl ?? ""))
                                .frame(height: wide ? 170 : 130)
                            Text(PhotosCard.planTitle(plan.title)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .buttonStyle(.pressable)
                }
            }
        }
    }
}

/// An image shown whole (not cropped) on white, for floor plans.
struct FittedImage: View {
    let url: URL?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white)
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit().padding(4)
                } else if phase.error != nil {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
        }
    }
}

// MARK: - One item: view it, save it

enum MediaItem: Identifiable, Hashable {
    case photo(ListingImage)
    case plan(FloorPlan)
    case video(ListingVideo)

    var id: String {
        switch self {
        case .photo(let p): return "photo-" + p.stableID
        case .plan(let f): return "plan-" + f.id
        case .video(let v): return "video-" + v.id
        }
    }

    var title: String {
        switch self {
        case .photo(let p): return p.index.map { "Photo \($0 + 1)" } ?? "Photo"   // Aryeo counts photos from 0
        case .plan(let f): return PhotosCard.planTitle(f.title)
        case .video(let v): return PhotosCard.cleanTitle(v.title)
        }
    }

    /// What's shown on screen.
    var displayURL: URL? {
        switch self {
        case .photo(let p): return URL(string: p.largeUrl ?? p.originalUrl ?? "")
        case .plan(let f): return URL(string: f.largeUrl ?? f.originalUrl ?? "")
        case .video(let v):
            // Aryeo's videos stream from Mux; the .m3u8 address is the iPhone-playable stream.
            guard let s = v.playbackUrl else { return nil }
            return URL(string: s.hasSuffix(".m3u8") ? s : s + ".m3u8")
        }
    }

    /// The full-quality file that gets saved.
    var saveURL: URL? {
        switch self {
        case .photo(let p): return URL(string: p.originalUrl ?? p.largeUrl ?? "")
        case .plan(let f): return URL(string: f.originalUrl ?? f.largeUrl ?? "")
        case .video(let v): return URL(string: v.downloadUrl ?? "")
        }
    }

    var isVideo: Bool { if case .video = self { return true }; return false }
    var isPlan: Bool { if case .plan = self { return true }; return false }

    /// Small picture for the filmstrip.
    var thumbURL: URL? {
        switch self {
        case .photo(let p): return URL(string: p.thumbnailUrl ?? p.largeUrl ?? "")
        case .plan(let f): return URL(string: f.thumbnailUrl ?? f.largeUrl ?? "")
        case .video(let v): return URL(string: v.thumbnailUrl ?? "")
        }
    }
}

struct MediaViewer: View {
    let item: MediaItem
    @Environment(\.dismiss) private var dismiss
    @State private var saver = SingleSaver()
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Group {
                    if item.isVideo {
                        if let player { VideoPlayer(player: player) } else { ProgressView() }
                    } else {
                        AsyncImage(url: item.displayURL) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFit()
                            } else if phase.error != nil {
                                ContentUnavailableView("Couldn't load", systemImage: "photo")
                            } else {
                                ProgressView()
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Button {
                    Task { await saver.save(item) }
                } label: {
                    HStack {
                        if saver.state == .working { ProgressView().tint(.white) } else { Image(systemName: saver.icon) }
                        Text(saver.label(isVideo: item.isVideo))
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(.white)
                    .background(saver.state == .saved ? Color.green : Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(saver.state == .working || item.saveURL == nil)

                if case .failed(let why) = saver.state {
                    Text(why).font(.footnote).foregroundStyle(.red)
                }
            }
            .padding(16)
            .navigationTitle(item.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear {
                if item.isVideo, let url = item.displayURL { player = AVPlayer(url: url) }
            }
            .onDisappear { player?.pause() }
        }
    }
}

/// Saves one photo, floor plan or video to the Photos app (add-only permission).
@Observable
@MainActor
final class SingleSaver {
    enum State: Equatable { case idle, working, saved, failed(String) }
    var state: State = .idle

    var icon: String {
        switch state {
        case .saved: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle"
        default: return "square.and.arrow.down"
        }
    }

    func label(isVideo: Bool) -> String {
        switch state {
        case .idle, .failed: return "Save to Photos"
        case .working: return isVideo ? "Downloading video…" : "Saving…"
        case .saved: return "Saved to Photos"
        }
    }

    /// Pass `transfers` to show a video's progress in the pill and on the Lock Screen (photos are quick, so they don't).
    func save(_ item: MediaItem, transfers: TransferCenter? = nil) async {
        guard let url = item.saveURL else { return }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            state = .failed("Allow photo saving in Settings › ShootDesk › Photos.")
            return
        }
        state = .working
        do {
            if item.isVideo {
                // Full-quality .mov from Aryeo; can be a few hundred MB.
                transfers?.begin(title: item.title, kind: "Video", line: "0%")
                let file = try await ProgressDownload.file(from: url) { f in
                    Task { @MainActor in transfers?.progress(f * 0.97, line: "\(Int(f * 100))%") }
                }
                try await PHPhotoLibrary.shared().performChanges {
                    let options = PHAssetResourceCreationOptions()
                    options.shouldMoveFile = true
                    PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: file, options: options)
                }
            } else {
                let (data, _) = try await URLSession.shared.data(from: url)
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
                }
            }
            state = .saved
            if item.isVideo { transfers?.finish(ok: true, line: "100%") }
        } catch {
            state = .failed("Couldn't save it. Check your connection and try again.")
            if item.isVideo { transfers?.finish(ok: false, line: "Stopped") }
        }
    }
}

// MARK: - Save every photo

@Observable
@MainActor
final class PhotoSaver {
    enum State: Equatable {
        case idle, saving(Int), saved(Int), failed(String)

        var isBusy: Bool { if case .saving = self { return true }; return false }
        var isDone: Bool { if case .saved = self { return true }; return false }
        var icon: String {
            switch self {
            case .saved: return "checkmark.circle.fill"
            case .failed: return "exclamationmark.triangle"
            default: return "square.and.arrow.down"
            }
        }
        func label(total: Int) -> String {
            switch self {
            case .idle, .failed: return "Save all \(total)"
            case .saving(let n): return "Saving \(n) of \(total)…"
            case .saved(let n): return "Saved \(n) to Photos"
            }
        }
    }

    var state: State = .idle

    /// Downloads each full-resolution photo from Aryeo and adds it to the Photos library.
    /// Uses "add only" permission: the app can save photos but never see your library.
    func save(_ images: [ListingImage], title: String, transfers: TransferCenter) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            state = .failed("Allow photo saving in Settings › ShootDesk › Photos.")
            return
        }
        state = .saving(0)
        let total = images.count
        transfers.begin(title: title, kind: "\(total) photos", line: "0 of \(total)")
        var saved = 0
        var tried = 0
        for img in images {
            guard let s = img.originalUrl ?? img.largeUrl, let url = URL(string: s) else { continue }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
                }
                saved += 1
                state = .saving(saved)
            } catch {
            }
            tried += 1
            transfers.progress(Double(tried) / Double(max(total, 1)), line: "\(saved) of \(total)")
        }
        state = saved > 0 ? .saved(saved) : .failed("Couldn't save the photos. Check your connection and try again.")
        transfers.finish(ok: saved > 0, line: saved == total ? "All \(total)" : "\(saved) of \(total)")
    }
}


// MARK: - Full-screen gallery (viewing and presenting)

struct GalleryRequest: Identifiable {
    let id = UUID()
    let items: [MediaItem]
    let start: Int
    let present: Bool
    /// The opening card when presenting: the street over the hero photo.
    var title: String? = nil
    var subtitle: String? = nil
    var cover: URL? = nil
}

/// Keeps full-size photos in memory once loaded, so swiping back and forth is instant.
@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, UIImage>()
    private var running: [URL: Task<UIImage?, Never>] = [:]

    init() { cache.totalCostLimit = 350 * 1024 * 1024 }

    func cached(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    func load(_ url: URL) async -> UIImage? {
        if let hit = cached(url) { return hit }
        if let task = running[url] { return await task.value }
        let task = Task<UIImage?, Never> {
            guard let (data, _) = try? await URLSession.shared.data(from: url), let img = UIImage(data: data) else { return nil }
            return await img.byPreparingForDisplay() ?? img
        }
        running[url] = task
        let img = await task.value
        running[url] = nil
        if let img { cache.setObject(img, forKey: url as NSURL, cost: Int(img.size.width * img.size.height * img.scale * img.scale * 4)) }
        return img
    }

    func prefetch(_ urls: [URL]) { for u in urls where cached(u) == nil && running[u] == nil { Task { _ = await load(u) } } }
}

struct GalleryViewer: View {
    @Environment(AppModel.self) private var model
    let items: [MediaItem]
    @State private var index: Int
    @State private var presenting: Bool
    @State private var chrome: Bool
    @State private var zoomed = false
    @State private var saver = SingleSaver()
    @State private var pull: CGFloat = 0
    @State private var showingCover: Bool
    /// How far a sideways swipe has moved the photos, and which way the current drag is going.
    @State private var dragX: CGFloat = 0
    @State private var dragAxis: Axis?
    @Environment(\.dismiss) private var dismiss
    private let title: String?
    private let subtitle: String?
    private let cover: URL?

    init(request: GalleryRequest) {
        items = request.items
        let start = min(request.start, max(request.items.count - 1, 0))
        _index = State(initialValue: start)
        _presenting = State(initialValue: request.present)
        _chrome = State(initialValue: !request.present)
        _showingCover = State(initialValue: request.present && request.title != nil && request.cover != nil)
        title = request.title
        subtitle = request.subtitle
        cover = request.cover
    }

    private var current: MediaItem? { items.indices.contains(index) ? items[index] : nil }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // One photo per screen, edge to edge, laid out by hand: each page is exactly the screen's
            // full width (the Duo's camera corner included), so the picture is centred and the
            // neighbours never peek in. Swipe sideways to move, pull down to close.
            GeometryReader { geo in
                let w = geo.size.width
                ZStack {
                    ForEach([index - 1, index, index + 1].filter { items.indices.contains($0) }, id: \.self) { i in
                        page(items[i], i)
                            .frame(width: w, height: geo.size.height)
                            .offset(x: CGFloat(i - index) * w + dragX)
                    }
                }
                .frame(width: w, height: geo.size.height)
                .clipped()
                .contentShape(Rectangle())
                .gesture(swipe(width: w), including: zoomed ? .subviews : .all)
            }
            .ignoresSafeArea()
            .offset(y: pull)
            .scaleEffect(1 - min(pull, 300) / 1500)
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) { chrome.toggle() }
            }
            // Stays underneath while presenting so it's already on the right photo when you stop
            // (a page view built mid-slideshow can come up shifted to one side).
            .opacity(presenting ? 0 : 1)
            .allowsHitTesting(!presenting)

            if presenting {
                // Pitch mode: full bleed, a slow drift on each photo, and soft crossfades.
                SlideshowStage(item: current, index: index,
                               cover: showingCover ? SlideshowStage.Cover(title: title ?? "", subtitle: subtitle ?? "", url: cover) : nil,
                               onVideoEnd: { advance() })
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.3)) { showingCover = false; presenting = false; chrome = true }
                    }
                    .transition(.opacity)
            }

            if chrome {
                VStack(spacing: 0) {
                    topBar
                        .padding(.bottom, 24)
                        .background(LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                            .ignoresSafeArea())
                    Spacer()
                    filmstrip
                        .padding(.top, 20)
                        .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                            .ignoresSafeArea())
                }
                .transition(.opacity)
            }
        }
        .background(Color.black)
        .statusBarHidden(true)
        .persistentSystemOverlays(chrome ? .automatic : .hidden)
        .onAppear {
            // Video plays with sound even when the phone is on silent.
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            prefetch()
        }
        .onChange(of: index) { _, i in
            saver = SingleSaver()
            prefetch()
        }
        .task(id: "\(presenting)-\(index)-\(showingCover)") {
            guard presenting else { return }
            if showingCover {
                // The opening card holds, then the listing begins.
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if !Task.isCancelled && presenting { withAnimation(.easeInOut(duration: 1.2)) { showingCover = false } }
                return
            }
            // Photos and plans hold for 5 seconds; videos move on when they finish.
            guard let item = current, !item.isVideo else { return }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled && presenting { advance() }
        }
    }

    @ViewBuilder private func page(_ item: MediaItem, _ i: Int) -> some View {
        if item.isVideo {
            VideoPage(url: item.displayURL, active: i == index && !presenting)
        } else {
            ZoomableImage(url: item.displayURL, placeholder: item.thumbURL, onWhite: item.isPlan,
                          zoomed: i == index ? $zoomed : .constant(false))
        }
    }

    private func swipe(width w: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { v in
                if dragAxis == nil {
                    dragAxis = abs(v.translation.width) > abs(v.translation.height) ? .horizontal : .vertical
                }
                if dragAxis == .horizontal {
                    let atEnd = (index == 0 && v.translation.width > 0) || (index == items.count - 1 && v.translation.width < 0)
                    dragX = atEnd ? v.translation.width / 3 : v.translation.width
                } else if v.translation.height > 0 {
                    pull = v.translation.height
                }
            }
            .onEnded { v in
                if dragAxis == .horizontal {
                    var next = index
                    if v.predictedEndTranslation.width < -w / 3 { next += 1 }
                    if v.predictedEndTranslation.width > w / 3 { next -= 1 }
                    next = min(max(next, 0), items.count - 1)
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                        index = next
                        dragX = 0
                    }
                } else if pull > 140 {
                    dismiss()
                } else {
                    withAnimation(.spring) { pull = 0 }
                }
                dragAxis = nil
            }
    }

    private func advance() {
        guard !items.isEmpty else { return }
        withAnimation(.easeInOut(duration: presenting ? 1.2 : 0.6)) { index = (index + 1) % items.count }
    }

    private func prefetch() {
        let around = [index - 1, index + 1, index + 2].filter { items.indices.contains($0) }
        ImageCache.shared.prefetch(around.compactMap { items[$0].isVideo ? nil : items[$0].displayURL })
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            circleButton("xmark", label: "Close") { dismiss() }
            Spacer()
            VStack(spacing: 1) {
                Text("\(index + 1) of \(items.count)").font(.subheadline.weight(.semibold)).monospacedDigit()
                // Videos and plans get their name; for photos "3 of 21" says it all.
                if let c = current, c.isVideo || c.isPlan { Text(c.title).font(.caption).opacity(0.75) }
            }
            .foregroundStyle(.white)
            Spacer()
            circleButton(presenting ? "pause.fill" : "play.fill", label: presenting ? "Stop slideshow" : "Present") {
                withAnimation(.easeInOut(duration: 0.3)) {
                    presenting.toggle()
                    if presenting { chrome = false }
                }
            }
            if let url = current?.saveURL ?? current?.displayURL {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up").font(.body.weight(.semibold))
                        .frame(width: 44, height: 44).background(.ultraThinMaterial, in: Circle())
                }
                .foregroundStyle(.white)
            }
            if let item = current {
                circleButton(saver.state == .saved ? "checkmark" : saver.state == .working ? "ellipsis" : "arrow.down.to.line",
                             label: "Save to Photos") { Task { await saver.save(item, transfers: model.transfers) } }
                    .disabled(saver.state == .working || item.saveURL == nil)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func circleButton(_ icon: String, label: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: icon).font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityLabel(label)
    }

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                        Button { withAnimation { index = i } } label: {
                            ZStack {
                                RemotePhoto(url: item.thumbURL, cornerRadius: 6)
                                if item.isVideo { Image(systemName: "play.fill").font(.caption).foregroundStyle(.white).shadow(radius: 2) }
                            }
                            .frame(width: 66, height: 44)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white, lineWidth: i == index ? 2 : 0))
                            .opacity(i == index ? 1 : 0.6)
                        }
                        .buttonStyle(.plain)
                        .id(i)
                    }
                }
                .padding(.horizontal, 16)
            }
            .frame(height: 52)
            .padding(.bottom, 10)
            .onAppear { proxy.scrollTo(index, anchor: .center) }
            .onChange(of: index) { _, i in withAnimation { proxy.scrollTo(i, anchor: .center) } }
        }
    }
}

/// A photo or floor plan that fills the screen: pinch or double-tap to zoom, drag to look around.
struct ZoomableImage: View {
    let url: URL?
    var placeholder: URL? = nil
    var onWhite = false
    @Binding var zoomed: Bool

    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if onWhite { Color.white }
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                        .scaleEffect(scale)
                        .offset(offset)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    // The small version shows instantly while the full one loads.
                    RemotePhoto(url: placeholder, cornerRadius: 0).scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .blur(radius: 6)
                    ProgressView().tint(.white)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                MagnifyGesture()
                    .onChanged { v in scale = min(max(lastScale * v.magnification, 1), 5) }
                    .onEnded { _ in
                        lastScale = scale
                        if scale <= 1.01 { reset() } else { zoomed = true }
                    }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: scale > 1.01 ? 0 : 10_000)
                    .onChanged { v in
                        offset = CGSize(width: lastOffset.width + v.translation.width,
                                        height: lastOffset.height + v.translation.height)
                    }
                    .onEnded { _ in lastOffset = offset }
            )
            .onTapGesture(count: 2) {
                withAnimation(.spring(duration: 0.3)) {
                    if scale > 1.01 { reset() } else { scale = 2.5; lastScale = 2.5; zoomed = true }
                }
            }
        }
        .task(id: url) {
            guard let url else { return }
            image = ImageCache.shared.cached(url)
            if image == nil { image = await ImageCache.shared.load(url) }
        }
    }

    private func reset() {
        scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero; zoomed = false
    }
}

/// A video page: starts when you land on it, pauses when you swipe away.
struct VideoPage: View {
    let url: URL?
    let active: Bool
    var onFinished: () -> Void = {}
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black
            if let player { VideoPlayer(player: player) } else { ProgressView().tint(.white) }
        }
        .onAppear {
            if player == nil, let url { player = AVPlayer(url: url) }
            if active { player?.play() }
        }
        .onChange(of: active) { _, isActive in
            if isActive { player?.seek(to: .zero); player?.play() } else { player?.pause() }
        }
        .onDisappear { player?.pause() }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { note in
            if let item = note.object as? AVPlayerItem, item == player?.currentItem, active { onFinished() }
        }
    }
}

// MARK: - Presenting

/// What's on screen while presenting: the opening card, then each photo or video in turn.
struct SlideshowStage: View {
    struct Cover { let title: String; let subtitle: String; let url: URL? }

    let item: MediaItem?
    let index: Int
    let cover: Cover?
    let onVideoEnd: () -> Void
    @Environment(\.horizontalSizeClass) private var size

    var body: some View {
        ZStack {
            Color.black
            if let cover {
                KenBurnsPhoto(url: cover.url, seed: 1)
                    .overlay(alignment: .bottomLeading) { CoverTitle(cover: cover, wide: size == .regular) }
                    .id("cover")
                    .transition(.opacity)
            } else if let item {
                Group {
                    if item.isVideo {
                        VideoPage(url: item.displayURL, active: true, onFinished: onVideoEnd)
                    } else {
                        KenBurnsPhoto(url: item.displayURL, placeholder: item.thumbURL, seed: index, onWhite: item.isPlan)
                    }
                }
                .id(index)
                .transition(.opacity)
            }
        }
    }
}

/// The street in large serif type over the hero, rising in once.
private struct CoverTitle: View {
    let cover: SlideshowStage.Cover
    let wide: Bool
    @State private var shown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(cover.title)
                .font(.system(size: wide ? 52 : 38, weight: .semibold, design: .serif))
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            if !cover.subtitle.isEmpty {
                Text(cover.subtitle).font(.title3).opacity(0.85)
            }
            Text("Photographed by Horizon Home Media")
                .font(.footnote.weight(.medium))
                .opacity(0.65)
                .padding(.top, 10)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, wide ? 48 : 28)
        .padding(.top, 80)
        .padding(.bottom, wide ? 48 : 40)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 16)
        .onAppear { withAnimation(.easeOut(duration: 1.1).delay(0.3)) { shown = true } }
    }
}

/// A photo that slowly drifts while it's on screen. Close to the screen's shape it fills edge to edge;
/// otherwise (a wide photo on the folded phone) it sits whole over a soft, blurred copy of itself.
struct KenBurnsPhoto: View {
    let url: URL?
    var placeholder: URL? = nil
    let seed: Int
    var onWhite = false

    @State private var image: UIImage?
    @State private var drift = false

    private var anchor: UnitPoint {
        [UnitPoint.topLeading, .bottomTrailing, .topTrailing, .bottomLeading, .center][abs(seed) % 5]
    }

    var body: some View {
        GeometryReader { geo in
            let box = geo.size
            ZStack {
                if onWhite { Color.white }
                if let image {
                    let ia = image.size.width / max(image.size.height, 1)
                    let ba = box.width / max(box.height, 1)
                    let fill = !onWhite && abs(ia - ba) / max(ba, 0.01) < 0.4
                    if !fill && !onWhite {
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: box.width, height: box.height)
                            .blur(radius: 40)
                            .opacity(0.55)
                            .clipped()
                    }
                    Image(uiImage: image).resizable()
                        .aspectRatio(contentMode: fill ? .fill : .fit)
                        .frame(width: box.width, height: box.height)
                        .scaleEffect(onWhite ? 1 : (drift ? (fill ? 1.12 : 1.05) : 1), anchor: anchor)
                        .clipped()
                } else if let placeholder {
                    RemotePhoto(url: placeholder, cornerRadius: 0).scaledToFit()
                        .frame(width: box.width, height: box.height)
                        .blur(radius: 6)
                }
            }
            .frame(width: box.width, height: box.height)
            .clipped()
        }
        .task(id: url) {
            guard let url else { return }
            image = ImageCache.shared.cached(url)
            if image == nil { image = await ImageCache.shared.load(url) }
            withAnimation(.linear(duration: 7)) { drift = true }
        }
    }
}
