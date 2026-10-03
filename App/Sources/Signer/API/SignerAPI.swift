import Foundation
import HyperliquidSigning
import WalletCore

/// The only door into the signing process. Requests and replies are Codable JSON over one XPC call,
/// so the boundary is a small, auditable list rather than an object graph.
@objc public protocol SignerXPC {
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
    /// Removes the active wallet; asks for Touch ID first.
    case forget
    /// The address book's names and addresses as they were confirmed in person: what money may go to by name.
    case addressBook
    /// Saves entries to that book (a new one, or a changed address, name or memo): Touch ID first, every entry's whole
    /// address on the prompt. Money to them then needs no second approval.
    case saveAddresses([SignerAddress])
    /// Takes an entry out of the book (no prompt: removing one can't send money anywhere).
    case removeAddress(name: String, network: String)
    /// A single private key from another wallet (`ImportedKey`: a Solana key from Phantom, an EVM key from MetaMask),
    /// stored like a phrase and added as a wallet that signs only on that key's chain.
    case importPrivateKey(key: String)
    /// The wallet every signature uses from now on; Touch ID first when one is already in use.
    case setActiveWallet(id: String)
    /// Removes one wallet with its trading key and approved addresses; Touch ID first.
    case removeWallet(id: String)
    /// The user's own name for a wallet («Main», «Trading»).
    case renameWallet(id: String, label: String)
    /// Signs a Solana transaction after the guard checks it. `accounts`: the full account list the app resolved.
    /// `extraPrograms`: programs outside the built-in list that the user allowed for this one transaction
    /// (a dApp in the browser); the Touch ID prompt names them.
    case signSolana(wire: Data, accounts: [String], recipients: [String], tokenOwners: [String: String], extraPrograms: [String] = [])
    /// Sign-in text from a site. Refused when the bytes are a Solana transaction message in disguise.
    case signSolanaMessage(message: Data)
    /// EVM personal_sign (EIP-191) with the main EVM key; a bare 32-byte hash is refused.
    case signPersonal(message: Data)
    /// EVM eth_signTypedData_v4: the signer parses the JSON and hashes it itself. Token spending permissions (Permit,
    /// Permit2…), Hyperliquid's own actions, payments by signature (EIP-3009 and the like) and nested types are refused.
    case signTypedData(json: Data)
    /// An EIP-1559 transaction from a site. The signer decodes the calldata itself and refuses unlimited approvals,
    /// setApprovalForAll, credit delegation, permit and transferFrom out of the user, and a fee past the network's cap;
    /// coins, tokens, NFTs and a spender that isn't a contract ihatecrypto uses go only to an address in `recipients`.
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
    /// A Hyperliquid trading key for a Ledger's account (`owner`: the Ledger's EVM address), made inside the signer once
    /// when `create`. The Ledger signs its approval itself, so the signer never holds the Ledger's key, and this key
    /// can't withdraw. Reply: agentAddress (nil when there is none), agentActive.
    case ledgerAgent(owner: String, create: Bool)
    /// The app reports whether Hyperliquid accepted the Ledger's approval of that key. Turning a key back on after
    /// `lock` paused it asks for Touch ID.
    case setLedgerAgentActive(owner: String, active: Bool)
    /// An order, cancel or leverage change for the Ledger's account, signed by its trading key; nothing else. Money
    /// that leaves the account is signed on the Ledger.
    case signLedgerAgentL1(owner: String, action: MsgPack, nonce: UInt64)
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
    /// Sells native NEAR through 1Click. The signer builds the ONE wrap.near transaction itself from these plain fields
    /// (`NearTransaction.intentDeposit`): wrap exactly `amount` yoctoNEAR from our implicit account (m/44'/397'/0')
    /// and send that wNEAR to `depositAddress`, a 64-hex NEAR account, confirmed in person as a new recipient.
    /// Reply: `signedRaw` = the borsh SignedTransaction.
    case signNearIntentDeposit(amount: String, depositAddress: String, nonce: UInt64, blockHash: Data)
    /// A native NEAR transfer the signer builds itself; the receiver must be one of `recipients` (saved addresses) and
    /// passes the new-recipient Touch ID rule.
    case signNearTransfer(amount: String, receiver: String, recipients: [String], nonce: UInt64, blockHash: Data)
    /// DeleteAccount of the wallet's NEAR account into `beneficiary` (one of `recipients`), after a Touch ID prompt that
    /// says so in plain words.
    case signNearDeleteAccount(beneficiary: String, recipients: [String], nonce: UInt64, blockHash: Data)
    /// A new automation wallet (one at most, next to a Touch ID one): a phrase made here that signs without Touch ID,
    /// for the budget of scheduled tasks. Asks for Touch ID first; the wallet that signs stays the same.
    case createAutomationWallet
    /// `request` signed by the automation wallet `id` while another wallet stays active: a scheduled task's move.
    /// Only a money move's signature passes (no wallet changes, no site messages), with the same guard, and «our
    /// addresses» and the approved ones are that wallet's own.
    indirect case asWallet(id: String, request: SignerRequest)
}

/// One wallet the signer holds, public parts only: its name, what it can sign for, its addresses.
/// A saved address as the signer keeps it: the name money goes to and the address the user confirmed for it in person.
/// The app's file keeps only how an entry looks (its picture, star, notes); a name sends only to the address here.
public struct SignerAddress: Codable, Sendable, Equatable, Hashable {
    public var name: String
    /// AddressCheck.Network's raw value: «solana», «base», «near»…
    public var network: String
    public var address: String
    /// An exchange's memo or tag: it decides whose account a deposit lands in, so it's confirmed with the address.
    public var memo: String

    public init(name: String, network: String, address: String, memo: String = "") {
        (self.name, self.network, self.address, self.memo) = (name, network, address, memo)
    }

    /// The same entry: the name in any case, a 0x address in any case, a Solana or NEAR one exactly.
    public func same(name other: String, network net: String, address a: String) -> Bool {
        name.lowercased() == other.lowercased() && network == net && (address.hasPrefix("0x") ? address.lowercased() == a.lowercased() : address == a)
    }
}

public struct SignerWallet: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    /// "phrase": every chain from a recovery phrase; "solana" or "evm": one private key, that chain only.
    public var kind: String
    public var solana: String?
    public var evm: String?
    public var near: String?
    /// A test wallet: made fresh in the app for small amounts, it signs without Touch ID (nil in older registries: no).
    /// Only it may sign what came through the local debug API.
    public var test: Bool?
    /// The automation wallet: made fresh in the app for scheduled tasks' budget, it signs without Touch ID, and only
    /// what a task asks for by its id (`SignerRequest.asWallet`), never from the debug API. It isn't a test wallet.
    public var automation: Bool?

    public init(id: String, label: String, kind: String, solana: String?, evm: String?, near: String?, test: Bool? = nil, automation: Bool? = nil) {
        (self.id, self.label, self.kind, self.solana, self.evm, self.near, self.test, self.automation) = (id, label, kind, solana, evm, near, test, automation)
    }

    public var isTest: Bool { test == true }
    public var isAutomation: Bool { automation == true }

    /// Wallet «1» is the one ihatecrypto held before several wallets: its Keychain items keep their old names.
    public static let firstID = "1"

    /// The registry the signer keeps. Before several wallets there was one sealed seed and its addresses in the
    /// signer's defaults: that becomes wallet «1», «Main», active — nothing is re-sealed and no prompt appears.
    public static func migrated(_ registry: [SignerWallet]?, seedPresent: Bool, solana: String?, evm: String?, near: String?) -> [SignerWallet] {
        if let registry { return registry }
        guard seedPresent, solana != nil || evm != nil else { return [] }
        return [SignerWallet(id: firstID, label: "Main", kind: "phrase", solana: solana, evm: evm, near: near)]
    }

    /// «this wallet has no Solana key» when a key wallet is asked to sign on another chain.
    public func missing(_ chain: String) -> String? {
        let has = switch chain {
        case "solana": solana != nil
        case "evm": evm != nil
        default: near != nil
        }
        guard !has else { return nil }
        let name = ["solana": "Solana", "evm": "EVM (Hyperliquid, Base…)", "near": "NEAR"][chain] ?? chain
        return "The wallet «\(label)» has no \(name) key: it holds only \(kind == "solana" ? "a Solana" : kind == "evm" ? "an EVM" : "a") key. Switch wallets (Settings → Key and signing) or import one that has it."
    }
}

public enum SignerSession {
    /// 1, 5, 15 or 30 minutes; 1 minute until the user picks another. With that minute the app also ends the session
    /// when the move is done (`endSession`), so one Touch ID covers one move.
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
    /// Every wallet the signer holds (public parts) and the id of the one in use.
    public var wallets: [SignerWallet]?
    public var activeWallet: String?
    /// Seconds one Touch ID confirmation keeps signing open.
    public var sessionLength: Int?
    public var action: MsgPack?
    public var nonce: UInt64?
    /// The address book as the signer keeps it (`.addressBook`, `.saveAddresses`, `.removeAddress`).
    public var addresses: [SignerAddress]?
    public var checks: [String] = []
    public var problems: [String] = []

    public init(ok: Bool, error: String? = nil) {
        self.ok = ok
        self.error = error
    }
}

/// App side: talks to the XPC service embedded in the bundle. Unavailable when running from `swift run`.
public final class SignerClient: @unchecked Sendable {
    public static let serviceName = "app.ihatecrypto.mac.signer"
    /// The service ships inside ihatecrypto.app; a `swift run` build has none.
    public static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appending(path: "Contents/XPCServices/Signer.xpc").path)
    }
    private let connection: NSXPCConnection

    public init() {
        connection = NSXPCConnection(serviceName: Self.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: SignerXPC.self)
        connection.resume()
    }

    deinit { connection.invalidate() }

    /// Set while ihatecrypto handles a message from its local debug API (DebugAPI.swift): only status requests pass, so
    /// nothing that came from outside the window can sign or change the key, whatever path the message takes —
    /// except a trade's signatures while a test wallet signs (the user made it for exactly that; no Touch ID).
    /// Adding, switching, renaming or removing wallets never passes.
    @TaskLocal public static var untrusted = false

    public func send(_ request: SignerRequest) async throws -> SignerReply {
        if Self.untrusted {
            switch request {
            case .status, .nearAddress, .endSession, .ledgerAgent(_, false), .addressBook: break
            case .signSolana, .signEVMTransaction, .signHyperliquidL1, .signHyperliquidUser, .signRelayNonceMapping,
                 .signNearIntentDeposit, .signNearTransfer, .signNearDeleteAccount:
                let status = try await Self.$untrusted.withValue(false) { try await send(.status) }
                guard status.wallets?.first(where: { $0.id == status.activeWallet })?.isTest == true else {
                    throw WalletError("Nothing is signed from the debug API while a Touch ID wallet signs: confirm money moves in ihatecrypto’s window, or switch to a test wallet.")
                }
            default: throw WalletError("Nothing is signed from the debug API: confirm money moves in ihatecrypto’s window.")
            }
        }
        let body = try JSONEncoder().encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                continuation.resume(throwing: WalletError("The signer is unavailable: \(error.localizedDescription)"))
            } as? SignerXPC
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
