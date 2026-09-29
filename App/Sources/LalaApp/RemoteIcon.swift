import AppKit
import ImageIO
import SwiftUI
import Synchronization

/// A token's icon from a third-party URL (Jupiter, DexScreener, Robinhood's registry). AsyncImage kept nothing: it
/// fetched again whenever a row was recreated and decoded 256–1024 px files (some of them MBs, from IPFS) at full size
/// for a 20 pt circle. This one fetches once, decodes off the main thread at 3× the drawn size (still sharp on a
/// zoomed canvas) and keeps the result. No fade: an animation would tick the whole window's graph for every icon.
struct RemoteIcon<Placeholder: View>: View {
    let url: URL?
    let size: CGFloat
    let contentMode: ContentMode
    let placeholder: Placeholder
    /// The image loaded, with its URL: a row whose URL changes doesn't keep showing the old icon.
    @State private var loaded: (url: URL, image: CGImage)?

    init(url: URL?, size: CGFloat, contentMode: ContentMode = .fill, @ViewBuilder placeholder: () -> Placeholder) {
        self.url = url
        self.size = size
        self.contentMode = contentMode
        self.placeholder = placeholder()
    }

    private var pixels: Int { Int((size * 3).rounded(.up)) }

    var body: some View {
        // A row recreated with its icon already kept shows it at once, not the placeholder for a frame.
        let image = url.flatMap { u in loaded?.url == u ? loaded?.image : RemoteIconLoader.shared.cached(u, pixels: pixels) }
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: contentMode)
                    .frame(width: size, height: size).clipShape(Circle())
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .task(id: url) {
            guard let url, loaded?.url != url, let image = await RemoteIconLoader.shared.image(url, pixels: pixels) else { return }
            loaded = (url, image)
        }
    }
}

/// Fetches, downsamples and keeps the icons for every RemoteIcon. Off the main actor; NSCache, URLSession, URLCache
/// and the Mutex are thread-safe, hence @unchecked Sendable.
nonisolated final class RemoteIconLoader: @unchecked Sendable {
    static let shared = RemoteIconLoader()
    /// A third party picks these URLs: a file bigger than any icon needs is refused, not downloaded to the end.
    static let maxBytes = 5 << 20

    /// Decoded icons, keyed by URL and pixel size; about 600 at 34 pt before the oldest go.
    private let images: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 32 << 20
        return cache
    }()
    /// The downloads under way, so rows asking for one icon at once share a request.
    private let loading = Mutex<[String: Task<CGImage?, Never>]>([:])
    /// The files as downloaded, across launches. Read and written here, not by the session, so a response's
    /// no-cache headers can't make every launch fetch every icon again.
    /// In the app's own caches folder: the app isn't sandboxed, so a bare «RemoteIcons» would sit in ~/Library/Caches.
    private let files = URLCache(memoryCapacity: 4 << 20, diskCapacity: 100 << 20,
                                 directory: URL.cachesDirectory.appending(path: "app.lala.mac/RemoteIcons"))
    /// No cookies or credentials go to (or come from) the icon hosts: an ephemeral session still keeps cookies for the
    /// run, so they're refused outright. A slow host can't hold a request (and every row sharing it) past 30 s.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    func cached(_ url: URL, pixels: Int) -> CGImage? { images.object(forKey: Self.key(url, pixels) as NSString) }

    /// The icon at most `pixels` on its longer side; nil when it can't be fetched or read. Only http(s).
    func image(_ url: URL, pixels: Int) async -> CGImage? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        let key = Self.key(url, pixels)
        if let hit = images.object(forKey: key as NSString) { return hit }
        let task = loading.withLock { running in
            if let task = running[key] { return task }
            let task = Task {
                let image = await self.load(url, pixels: pixels)
                if let image { self.images.setObject(image, forKey: key as NSString, cost: image.bytesPerRow * image.height) }
                self.loading.withLock { $0[key] = nil }
                return image
            }
            running[key] = task
            return task
        }
        return await task.value
    }

    private static func key(_ url: URL, _ pixels: Int) -> String { "\(pixels) \(url.absoluteString)" }

    private func load(_ url: URL, pixels: Int) async -> CGImage? {
        guard let data = await fetch(url) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: pixels,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return image
        }
        // ImageIO doesn't read SVG, which some token icons are; NSImage does, drawn at the same size.
        guard let vector = NSImage(data: data), vector.size.width > 0, vector.size.height > 0 else { return nil }
        let scale = CGFloat(pixels) / max(vector.size.width, vector.size.height)
        var rect = CGRect(x: 0, y: 0, width: (vector.size.width * scale).rounded(), height: (vector.size.height * scale).rounded())
        return vector.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private func fetch(_ url: URL) async -> Data? {
        let request = URLRequest(url: url)
        if let hit = files.cachedResponse(for: request) { return hit.data }
        guard let (bytes, response) = try? await session.bytes(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.expectedContentLength <= Int64(Self.maxBytes) else { return nil }
        // The declared length can lie or be missing: count while reading, and stop past the limit.
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > Self.maxBytes { return nil }
            }
        } catch { return nil }
        files.storeCachedResponse(CachedURLResponse(response: response, data: data), for: request)
        return data
    }
}
