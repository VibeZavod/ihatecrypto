import Foundation
import WalletCore

/// ENS names (vitalik.eth) to addresses, read on Ethereum itself: the registry names the name's resolver, the resolver its
/// address (addr(bytes32)). Only plain ASCII labels: a look-alike letter is a different name, so it's refused rather than
/// normalized. A name resolved off-chain (CCIP-Read, e.g. a Base name) isn't read here: the resolver's call reverts.
public enum ENS {
    public static let registry = "0x00000000000c2e074ec69a0dfb2997ba6c7d2e1e"

    /// Whether `name` is a name ihatecrypto reads: lowercase ASCII labels of letters, digits and hyphens, ending in .eth.
    public static func isName(_ name: String) -> Bool {
        name.wholeMatch(of: /[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)*\.eth/) != nil
    }

    /// EIP-137's namehash: keccak256(parent's node ‖ keccak256(label)), from the right.
    public static func namehash(_ name: String) -> Data {
        name.split(separator: ".").reversed().reduce(Data(count: 32)) { node, label in Keccak.hash256(node + Keccak.hash256(Data(label.utf8))) }
    }

    /// The address `name` points at now, checksummed; an error when it has no resolver or no address.
    public static func resolve(_ name: String, rpc: EVMRPC = .ethereum) async throws -> String {
        guard isName(name) else { throw WalletError("\(name) isn't an ENS name ihatecrypto reads: plain letters, digits and hyphens, ending in .eth.") }
        let node = namehash(name)
        guard let resolver = ABI.address(in: try await rpc.read(registry, Data([0x01, 0x78, 0xb8, 0xbf]) + node), word: 0),
              resolver != "0x" + String(repeating: "0", count: 40) else { throw WalletError("\(name) has no resolver on Ethereum: it isn't registered, or it lives elsewhere.") }
        let answer: Data
        do { answer = try await rpc.read(resolver, Data([0x3b, 0x3b, 0x57, 0xde]) + node) }
        catch { throw WalletError("\(name)'s resolver doesn't answer on Ethereum (an off-chain name?). Paste the address itself.") }
        guard let address = ABI.address(in: answer, word: 0), address != "0x" + String(repeating: "0", count: 40) else {
            throw WalletError("\(name) points at no address.")
        }
        return EVMAccount.checksum(String(address.dropFirst(2)))
    }
}
