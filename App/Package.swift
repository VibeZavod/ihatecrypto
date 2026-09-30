// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Lala",
    // en.lproj/InfoPlist.strings (the app's display name) makes SwiftPM ask for a default language.
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        // For the Xcode project (project.yml) that builds LALA.app and its signing service.
        .library(name: "LalaKit", targets: [
            "LalaCore", "LLMCore", "LLMCatalog", "WalletCore", "TxGuard", "GuardJev", "SignerAPI", "HyperliquidSigning", "SolanaChain",
            "TradeExecution", "ExecutionCore", "DeFiJupiterLend", "EVMChain", "DeFiKamino", "DeFiYields", "Ledger",
        ]),
        .library(name: "LalaSignerKit", targets: ["SignerAPI", "WalletCore", "TxGuard", "HyperliquidSigning", "SolanaChain", "EVMChain"]),
    ],
    dependencies: [
        // libsecp256k1 from Bitcoin Core: secp256k1 keys and recoverable ECDSA for EVM and Hyperliquid signatures.
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1", exact: "0.23.2"),
    ],
    targets: [
        // Model access: one protocol in Core, one folder per way to connect, Catalog lists them all.
        .target(name: "LLMCore", path: "Sources/LLM/Core"),
        .target(name: "LLMAPIKey", dependencies: ["LLMCore"], path: "Sources/LLM/APIKey"),
        .target(name: "LLMOpenRouter", dependencies: ["LLMCore", "LLMAPIKey"], path: "Sources/LLM/OpenRouter"),
        .target(name: "LLMChatGPT", dependencies: ["LLMCore"], path: "Sources/LLM/ChatGPT"),
        .target(name: "LLMClaudeCode", dependencies: ["LLMCore"], path: "Sources/LLM/ClaudeCode"),
        .target(
            name: "LLMCatalog",
            dependencies: ["LLMCore", "LLMAPIKey", "LLMOpenRouter", "LLMChatGPT", "LLMClaudeCode"],
            path: "Sources/LLM/Catalog"
        ),
        .executableTarget(name: "LalaLLMCheck", dependencies: ["LLMCatalog", "LLMCore", "LalaCore"], path: "Sources/LLM/Check"),

        // Keys and signatures: BIP-39, derivation, Keccak, EIP-712. Knows nothing about protocols or UI.
        .target(name: "WalletCore", dependencies: [.product(name: "P256K", package: "swift-secp256k1")], path: "Sources/Wallet/Core"),
        // Hyperliquid wire format and signing, checked against the official Python SDK vectors.
        .target(name: "HyperliquidSigning", dependencies: ["WalletCore"], path: "Sources/Protocols/Hyperliquid"),
        .target(name: "SolanaChain", dependencies: ["WalletCore"], path: "Sources/Chains/Solana"),
        .target(name: "EVMChain", dependencies: ["WalletCore", .product(name: "P256K", package: "swift-secp256k1")], path: "Sources/Chains/EVM"),
        // Write-before-send journal; later the approval envelope and step states.
        .target(name: "ExecutionCore", path: "Sources/Execution", exclude: ["Trade"]),
        .target(name: "JupiterSwap", path: "Sources/Protocols/Jupiter"),
        .target(name: "OneClickKit", path: "Sources/Protocols/OneClick"),
        .target(name: "RelayBridge", dependencies: ["SolanaChain", "WalletCore"], path: "Sources/Protocols/Relay"),
        // DeFi: one folder per protocol. Jupiter Lend Earn first.
        .target(name: "DeFiJupiterLend", path: "Sources/DeFi/JupiterLend"),
        .target(name: "DeFiKamino", path: "Sources/DeFi/Kamino"),
        // Where money earns now across the DeFi modules: lending, liquid staking, Hyperliquid's HLP.
        .target(name: "DeFiYields", dependencies: ["DeFiJupiterLend", "DeFiKamino"], path: "Sources/DeFi/Yields"),
        // Runs an approved plan: bridge, leverage, entry, stop and take, through whichever signer holds the keys.
        .target(name: "TradeExecution", dependencies: ["LalaCore", "ExecutionCore", "HyperliquidSigning", "SolanaChain", "EVMChain", "RelayBridge", "TxGuard", "WalletCore",
                                                       "DeFiJupiterLend", "JupiterSwap", "DeFiKamino", "DeFiYields", "OneClickKit"],
                path: "Sources/Execution/Trade"),
        // Last check before signing: allowed programs, recipients bound to an approved quote, simulated balances.
        .target(name: "TxGuard", dependencies: ["SolanaChain", "HyperliquidSigning"], path: "Sources/Guard/Core"),
        // Signing process: the XPC protocol shared by the app and LalaSigner, and the service itself
        // (built as an .xpc by project.yml; the SwiftPM target only compile-checks it).
        .target(name: "SignerAPI", dependencies: ["WalletCore", "HyperliquidSigning"], path: "Sources/Signer/API"),
        .executableTarget(name: "LalaSigner", dependencies: ["SignerAPI", "WalletCore", "TxGuard", "HyperliquidSigning", "SolanaChain", "EVMChain"],
                          path: "Sources/Signer/Service"),
        // A Ledger over USB (or its emulator over TCP): the Ethereum and Solana apps sign what the guard let through.
        .target(name: "Ledger", dependencies: ["WalletCore", "EVMChain", "SolanaChain", "HyperliquidSigning", "TxGuard", "TradeExecution"],
                path: "Sources/Wallet/Ledger"),
        // Jev (TypeSafe via OpenRouter) as an extra classifier for untrusted text; it can only add problems.
        .target(name: "GuardJev", dependencies: ["TxGuard"], path: "Sources/Guard/Jev"),
        .executableTarget(
            name: "LalaWalletCheck",
            dependencies: ["WalletCore", "HyperliquidSigning", "SolanaChain", "JupiterSwap", "OneClickKit", "LalaCore", "ExecutionCore", "TxGuard", "GuardJev", "DeFiJupiterLend", "RelayBridge", "EVMChain", "TradeExecution", "DeFiKamino", "DeFiYields", "Ledger"],
            path: "Sources/Wallet/Check"
        ),

        // Trading plan: knows only the LLMClient protocol, not the providers.
        .target(name: "LalaCore", dependencies: ["LLMCore", "WalletCore", "OneClickKit", "RelayBridge"]),
        .executableTarget(
            name: "LalaApp",
            dependencies: ["LalaCore", "LLMCore", "LLMCatalog", "WalletCore", "TxGuard", "GuardJev", "SignerAPI", "HyperliquidSigning", "SolanaChain",
                           "TradeExecution", "ExecutionCore", "DeFiJupiterLend", "EVMChain", "DeFiKamino", "DeFiYields", "Ledger"],
            // Logos, sounds and the stories are bundled by the Xcode project; `swift run` shows lettered circles instead.
            exclude: ["Logos", "Sounds", "WhatsNew"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),

        .testTarget(name: "LalaCoreTests", dependencies: ["LalaCore", "LLMCore"]),
        .testTarget(name: "DeFiTests", dependencies: ["DeFiYields"]),
        .testTarget(name: "WalletTests", dependencies: ["WalletCore", "HyperliquidSigning", "SolanaChain", "ExecutionCore", "TxGuard", "EVMChain", "TradeExecution", "SignerAPI", "Ledger"]),
        .testTarget(
            name: "LLMTests",
            dependencies: ["LLMCore", "LLMAPIKey", "LLMOpenRouter", "LLMChatGPT", "LLMClaudeCode", "LLMCatalog"]
        ),
    ]
)
