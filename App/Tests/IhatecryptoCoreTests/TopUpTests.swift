import Foundation
import Testing
@testable import IhatecryptoCore

@Test func topUpLinksCarryTheAmountCoinAndNetwork() {
    let sol = "6nod592sTfEWD3VSVPdQndLMVBCNmMc6ngt7MyGBK21j", evm = "0x976EA74026E726554dB657fA54763abd0C3a0aa9"
    let base = TopUpOrder.Network(key: "base", title: "Base", chainId: 8453, usdc: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913", coin: "ETH",
                                  explorer: "https://basescan.org", rpc: "https://mainnet.base.org")
    let tempo = TopUpOrder.Network(key: "tempo", title: "Tempo", chainId: 4217, usdc: "0x20c000000000000000000000b9537d11c60e8b50", coin: nil,
                                   explorer: "https://explore.tempo.xyz", rpc: "https://rpc.mainnet.tempo.xyz")
    let usdc = TopUpOrder(network: .solana, coin: .usdc, amount: Decimal(string: "20.5")!, recipient: sol)
    #expect(usdc.units == "20500000")
    #expect(usdc.payLink == "solana:\(sol)?amount=20.5&spl-token=EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v&label=ihatecrypto&message=Top%20up")
    let lamports = TopUpOrder(network: .solana, coin: .native, amount: Decimal(string: "0.02")!, recipient: sol)
    #expect(lamports.units == "20000000" && lamports.payLink == "solana:\(sol)?amount=0.02&label=ihatecrypto&message=Top%20up")
    let baseUSDC = TopUpOrder(network: base, coin: .usdc, amount: 100, recipient: evm)
    #expect(baseUSDC.payLink == "ethereum:0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913@8453/transfer?address=\(evm)&uint256=100000000")
    // Wei past UInt64 still prints whole, not as 1e+19.
    let eth = TopUpOrder(network: base, coin: .native, amount: 20, recipient: evm)
    #expect(eth.units == "20000000000000000000" && eth.payLink == "ethereum:\(evm)@8453?value=20000000000000000000")
    // Any amount: the link names the coin and the network, the wallet asks how much.
    #expect(TopUpOrder(network: .solana, coin: .usdc, amount: nil, recipient: sol).payLink
            == "solana:\(sol)?spl-token=EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v&label=ihatecrypto&message=Top%20up")
    #expect(TopUpOrder(network: base, coin: .usdc, amount: nil, recipient: evm).payLink == "ethereum:0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913@8453/transfer?address=\(evm)")
    // Any coin: only the address and the network, whatever the amount says.
    let any = TopUpOrder(network: base, coin: .any, amount: 20, recipient: evm)
    #expect(any.units == nil && any.symbol == "any coin" && any.payLink == "ethereum:\(evm)@8453")
    #expect(TopUpOrder(network: .solana, coin: .any, amount: nil, recipient: sol).payLink == "solana:\(sol)?label=ihatecrypto&message=Top%20up")
    // Tempo has no coin of its own: its dollar it is.
    #expect(TopUpOrder(network: tempo, coin: .native, amount: 5, recipient: evm).symbol == "USDC")
    // More digits than USDC has, nothing, or too much: no amount to ask for, and no link that would ask for another one.
    #expect(TopUpOrder(network: .solana, coin: .usdc, amount: Decimal(string: "1.0000001")!, recipient: sol).units == nil)
    #expect(TopUpOrder(network: .solana, coin: .usdc, amount: 0, recipient: sol).payLink == nil)
    #expect(TopUpOrder(network: base, coin: .usdc, amount: 2_000_000, recipient: evm).units == nil)
}
