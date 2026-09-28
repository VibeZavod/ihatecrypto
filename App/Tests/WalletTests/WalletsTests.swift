import CryptoKit
import Foundation
import SignerAPI
import Testing
@testable import WalletCore

/// RFC 8032, test 1: an ed25519 secret and its public key; a Solana address is base58 of that public key.
private let rfcSecret = Data(hex: "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")!
private let rfcPublic = Data(hex: "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")!

@Test func phantomBase58KeypairAndKeyFileGiveTheSameSolanaKey() throws {
    let keypair = rfcSecret + rfcPublic
    #expect(try ImportedKey.parse(Base58.encode(keypair)) == .solana(rfcSecret))
    #expect(try ImportedKey.parse("  " + Base58.encode(keypair) + "\n") == .solana(rfcSecret))
    let file = "[" + keypair.map { String($0) }.joined(separator: ",") + "]"
    #expect(try ImportedKey.parse(file) == .solana(rfcSecret))
    // Its address is base58 of RFC 8032's public key.
    #expect(try Base58.decode(try ImportedKey.solana(rfcSecret).address()) == rfcPublic)
    // The secret alone (32 bytes of base58) is accepted too.
    #expect(try ImportedKey.parse(Base58.encode(rfcSecret)) == .solana(rfcSecret))
}

@Test func aMangledSolanaKeyIsRefused() {
    var keypair = rfcSecret + rfcPublic
    keypair[63] ^= 1
    #expect(throws: WalletError.self) { try ImportedKey.parse(Base58.encode(keypair)) }
    #expect(throws: WalletError.self) { try ImportedKey.parse("[1,2,3]") }
    #expect(throws: WalletError.self) { try ImportedKey.parse("[" + Array(repeating: "300", count: 64).joined(separator: ",") + "]") }
    #expect(throws: WalletError.self) { try ImportedKey.parse(Base58.encode(Data(repeating: 7, count: 40))) }
}

/// web3.js accounts docs: this private key is 0x2c7536E3605D9C16a7a3D7b1898e529396a65c23.
@Test func metamaskHexKeyWithOrWithout0xIsAnEVMKey() throws {
    let hex = "4c0883a69102937d6231471b5dbb6204fe5129617082792ae468d01a3f362318"
    let key = Data(hex: hex)!
    #expect(try ImportedKey.parse(hex) == .evm(key))
    #expect(try ImportedKey.parse("0x" + hex.uppercased()) == .evm(key))
    #expect(try ImportedKey.evm(key).address() == "0x2c7536E3605D9C16a7a3D7b1898e529396a65c23")
    #expect(throws: WalletError.self) { try ImportedKey.parse(String(hex.dropLast(2))) }        // 62 digits
    #expect(throws: WalletError.self) { try ImportedKey.parse(String(repeating: "0", count: 64)) } // not a secp256k1 key
}

@Test func theSingleSeedBecomesWalletOneMainAndARegistryStaysAsItIs() {
    let first = SignerWallet.migrated(nil, seedPresent: true, solana: "Sol", evm: "0xE", near: "n")
    #expect(first == [SignerWallet(id: SignerWallet.firstID, label: "Main", kind: "phrase", solana: "Sol", evm: "0xE", near: "n")])
    #expect(SignerWallet.migrated(nil, seedPresent: false, solana: "Sol", evm: "0xE", near: nil).isEmpty)
    #expect(SignerWallet.migrated(nil, seedPresent: true, solana: nil, evm: nil, near: nil).isEmpty)
    let two = first + [SignerWallet(id: "ab12cd34", label: "Trading", kind: "evm", solana: nil, evm: "0xF", near: nil)]
    #expect(SignerWallet.migrated(two, seedPresent: true, solana: "Sol", evm: "0xE", near: "n") == two)
    #expect(SignerWallet.migrated([], seedPresent: true, solana: "Sol", evm: "0xE", near: "n").isEmpty) // removed stays removed
}

@Test func aKeyWalletSaysWhichKeyItLacks() throws {
    let evmOnly = SignerWallet(id: "x", label: "Trading", kind: "evm", solana: nil, evm: "0xF", near: nil)
    #expect(evmOnly.missing("evm") == nil)
    let message = try #require(evmOnly.missing("solana"))
    #expect(message.contains("«Trading» has no Solana key") && message.contains("an EVM key"))
    #expect(evmOnly.missing("near") != nil)
    let phrase = SignerWallet(id: "1", label: "Main", kind: "phrase", solana: "S", evm: "E", near: "N")
    #expect(["solana", "evm", "near"].allSatisfy { phrase.missing($0) == nil })
}
