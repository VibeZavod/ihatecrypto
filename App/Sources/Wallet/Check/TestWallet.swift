import Foundation
import WalletCore

/// A throwaway hot wallet for live tests with small amounts. The phrase sits in ~/.lala/test-wallet.txt
/// (folder 0700, file 0600), like Solana CLI's id.json. It is never printed. Not the app's key storage.
enum TestWallet {
    static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lala")
    static let file = folder.appendingPathComponent("test-wallet.txt")

    static func create() throws {
        guard !FileManager.default.fileExists(atPath: file.path) else {
            throw WalletError("Test wallet already exists: \(file.path). Not overwriting.")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: file.path, contents: Data(Mnemonic.generate().utf8), attributes: [.posixPermissions: 0o600])
    }

    static func keys() throws -> (solana: Data, evm: Data) {
        let phrase = try String(contentsOf: file, encoding: .utf8)
        let seed = try Mnemonic.seed(phrase)
        return (try Derivation.ed25519(seed: seed, path: WalletPath.solana(0)),
                try Derivation.secp256k1(seed: seed, path: WalletPath.evm(0)))
    }

    /// The NEAR key of the same phrase (m/44'/397'/0'); its implicit account is the hex of the public key.
    static func nearKey() throws -> Data {
        try Derivation.ed25519(seed: try Mnemonic.seed(try String(contentsOf: file, encoding: .utf8)), path: WalletPath.near(0))
    }

    static func nearAccount() throws -> String { try NearAccount.implicit(privateKey: try nearKey()) }

    static func addresses() throws -> (solana: String, evm: String) {
        let k = try keys()
        return (try SolanaAccount.address(privateKey: k.solana), try EVMAccount.address(privateKey: k.evm))
    }
}
