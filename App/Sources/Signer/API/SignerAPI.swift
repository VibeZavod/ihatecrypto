import Foundation
import HyperliquidSigning
import WalletCore

/// The only door into the signing process. Requests and replies are Codable JSON over one XPC call,
/// so the boundary is a small, auditable list rather than an object graph.
@objc public protocol LalaSignerXPC {
    func handle(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
}

public enum SignerRequest: Codable, Sendable {
    case status
    /// Validates and stores the seed; the phrase itself is not kept. `requirePresence`: Touch ID or password on every use
    /// (always, in a Release signer). Replacing a wallet that is already there asks for Touch ID first.
    case importMnemonic(phrase: String, passphrase: String, requirePresence: Bool)
    /// A new 12-word phrase made inside the signer from system randomness and stored like an import. The reply
    /// carries the phrase once, for the user to write down; the signer doesn't keep it.
    case createWallet(requirePresence: Bool)
    /// Removes the wallet; asks for Touch ID first.
    case forget
    /// Signs a Solana transaction after the guard checks it. `accounts`: the full account list the app resolved.
    /// `extraPrograms`: programs outside the built-in list that the user allowed for this one transaction
    /// (a dApp in the browser); the Touch ID prompt names them.
    case signSolana(wire: Data, accounts: [String], recipients: [String], tokenOwners: [String: String], extraPrograms: [String] = [])
    /// Sign-in text from a site. Refused when the bytes are a Solana transaction message in disguise.
    case signSolanaMessage(message: Data)
    /// EVM personal_sign (EIP-191) with the main EVM key; a bare 32-byte hash is refused.
    case signPersonal(message: Data)
    /// EVM eth_signTypedData_v4: the signer parses the JSON and hashes it itself. Token spending
    /// permissions (Permit, Permit2…) and nested types are refused.
    case signTypedData(json: Data)
    /// An EIP-1559 transaction from a site. The signer decodes the calldata itself and refuses unlimited approvals,
    /// setApprovalForAll, permit and transferFrom out of the user; a transfer goes only to an address in `recipients`.
    case signEVMTransaction(chainId: UInt64, nonce: UInt64, maxPriorityFee: UInt64, maxFee: UInt64, gasLimit: UInt64,
                            to: String, value: UInt64, data: Data, recipients: [String])
    /// Hyperliquid order/cancel (L1). The signer hashes the action itself.
    case signHyperliquidL1(action: MsgPack, nonce: UInt64, mainnet: Bool)
    /// Hyperliquid transfer-type action signed by the main key. The signer picks the EIP-712 schema from the
    /// action's own type and reads the values from the action, so what is signed is what the guard checked.
    case signHyperliquidUser(action: MsgPack, mainnet: Bool, recipients: [String])
    /// Relay's binding of our Hyperliquid deposit to an order; the signer requires wallet and depositor to be ours.
    case signRelayNonceMapping(wallet: String, depositor: String, id: Data, nonce: UInt64)
    /// Creates (once) a Hyperliquid agent key inside the signer and returns the approveAgent action signed by
    /// the main key. The agent can trade but not withdraw, so it needs no Touch ID afterwards.
    case enableAgent
    /// The app reports whether Hyperliquid accepted the approval; only then do orders use the agent key.
    /// Turning it back on asks for Touch ID when the key is paused.
    case setAgentActive(Bool)
    /// The NEAR implicit account of the same phrase (m/44'/397'/0'). Wallets imported before NEAR have it derived
    /// here once, which unlocks the seed; afterwards `status` returns it without touching the seed.
    case nearAddress
    /// Ends the Touch ID session and pauses the trading key: the next signature asks for Touch ID.
    case lock
    /// How long one Touch ID confirmation keeps signing open: one of `SignerSession.choices`, in seconds. A longer
    /// time than now asks for Touch ID first, so the app alone can't stretch it.
    case setSessionLength(seconds: Int)
    /// Ends the Touch ID session only (the Mac's screen locked or it went to sleep); the trading key stays as it is.
    case endSession
}

public enum SignerSession {
    /// 1, 5, 15 or 30 minutes; 1 minute until the user picks another.
    public static let choices = [60, 300, 900, 1800]
    public static let standard = 60
}

public struct SignerReply: Codable, Sendable {
    public var ok: Bool
    public var error: String?
    public var hasWallet: Bool?
    public var solanaAddress: String?
    public var evmAddress: String?
    public var nearAddress: String?
    /// Only in the reply to createWallet: the new phrase, for the user's paper backup.
    public var phrase: String?
    public var signedWire: Data?
    /// A signed raw EVM transaction.
    public var signedRaw: Data?
    public var signature: EVMSignature?
    /// A raw ed25519 signature (signed messages).
    public var signatureBytes: Data?
    public var agentAddress: String?
    public var agentActive: Bool?
    /// Seconds one Touch ID confirmation keeps signing open.
    public var sessionLength: Int?
    public var action: MsgPack?
    public var nonce: UInt64?
    public var checks: [String] = []
    public var problems: [String] = []

    public init(ok: Bool, error: String? = nil) {
        self.ok = ok
        self.error = error
    }
}

/// App side: talks to the XPC service embedded in the bundle. Unavailable when running from `swift run`.
public final class SignerClient: @unchecked Sendable {
    public static let serviceName = "app.lala.mac.signer"
    /// The service ships inside LALA.app; a `swift run` build has none.
    public static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appending(path: "Contents/XPCServices/LalaSigner.xpc").path)
    }
    private let connection: NSXPCConnection

    public init() {
        connection = NSXPCConnection(serviceName: Self.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: LalaSignerXPC.self)
        connection.resume()
    }

    deinit { connection.invalidate() }

    public func send(_ request: SignerRequest) async throws -> SignerReply {
        let body = try JSONEncoder().encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                continuation.resume(throwing: WalletError("The signer is unavailable: \(error.localizedDescription)"))
            } as? LalaSignerXPC
            guard let proxy else {
                continuation.resume(throwing: WalletError("The signer is unavailable."))
                return
            }
            proxy.handle(body) { data in
                do { continuation.resume(returning: try JSONDecoder().decode(SignerReply.self, from: data)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}
