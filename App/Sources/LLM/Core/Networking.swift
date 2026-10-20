// Off Apple, URLSession and friends live in FoundationNetworking; every module that imports LLMCore sees them here,
// with the one call corelibs Foundation lacks.
#if canImport(FoundationNetworking)
@_exported import FoundationNetworking
import Foundation

/// ponytail: the whole reply arrives before its first line (corelibs Foundation can't stream bytes), so a reply shows
/// at once instead of word by word; feed it from a URLSessionDataDelegate when the Windows chat wants the words live.
public struct ResponseBytes: AsyncSequence, Sendable {
    public typealias Element = UInt8
    let data: Data

    public struct AsyncIterator: AsyncIteratorProtocol {
        var bytes: Data.Iterator
        public mutating func next() async throws -> UInt8? { bytes.next() }
    }

    public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(bytes: data.makeIterator()) }

    /// Non-empty lines, as Foundation's `lines` gives them on a Mac.
    public var lines: AsyncThrowingStream<String, Error> {
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
        return AsyncThrowingStream { sink in
            for line in lines { sink.yield(line) }
            sink.finish()
        }
    }
}

extension URLSession {
    public func bytes(for request: URLRequest) async throws -> (ResponseBytes, URLResponse) {
        let (data, response) = try await data(for: request)
        return (ResponseBytes(data: data), response)
    }
}
#endif
