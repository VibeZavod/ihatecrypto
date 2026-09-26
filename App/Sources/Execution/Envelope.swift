import Foundation

/// What the user approves: limits, not a price snapshot. Live values may move inside the envelope
/// without asking again; anything outside stops the route and needs a new approval.
public struct Envelope: Codable, Sendable, Equatable {
    /// Most that may leave the source wallet, in source units.
    public let maxInput: Decimal
    /// Least that must arrive, in destination units.
    public let minOutput: Decimal
    /// Exact address funds may go to, once known (a quote's deposit address, the user's own account).
    public var destination: String?
    public let expires: Date

    public init(maxInput: Decimal, minOutput: Decimal, destination: String? = nil, expires: Date) {
        self.maxInput = maxInput
        self.minOutput = minOutput
        self.destination = destination
        self.expires = expires
    }

    /// From a quote the user saw: the same input, the output less `tolerance`, valid for `ttl` seconds.
    public static func approve(input: Decimal, quotedOutput: Decimal, tolerance: Decimal = Decimal(string: "0.01")!,
                               ttl: TimeInterval = 600, now: Date = Date()) -> Envelope {
        Envelope(maxInput: input, minOutput: quotedOutput * (1 - tolerance), expires: now.addingTimeInterval(ttl))
    }

    /// Empty when the live values fit. Each string says what is out of bounds, for the user.
    public func violations(input: Decimal, output: Decimal, destination: String? = nil, now: Date = Date()) -> [String] {
        var out: [String] = []
        if now > expires { out.append("The confirmation expired.") }
        if input > maxInput { out.append("Needs to send \(input), but at most \(maxInput) was approved.") }
        if output < minOutput { out.append("\(output) would arrive, but at least \(minOutput) was approved.") }
        if let approved = self.destination, let destination, approved != destination {
            out.append("Recipient address \(destination) doesn't match the approved \(approved).")
        }
        return out
    }
}
