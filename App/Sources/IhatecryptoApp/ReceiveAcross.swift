import CoreImage.CIFilterBuiltins
import IhatecryptoCore
import OneClickKit
import SignerAPI
import SwiftUI
import TradeExecution
import WalletCore

/// A deposit address 1Click opened for money coming from a network ihatecrypto has no wallet on.
struct AcrossDeposit: Equatable {
    let network: String
    let token: String
    let amount: Decimal
    let minimum: Decimal
    let address: String
    /// USDC that lands on Solana for `amount`, as 1Click quoted it.
    let arrives: String
    let until: Date
}

extension Workspace {
    /// «receive 50 USDC from Sui»: 1Click's deposit address there, on the canvas with what lands on Solana and until when;
    /// the in-transit row follows it until it lands. Nothing is signed; the NEAR account (for a refund) comes from the
    /// signer, which derives it the first time.
    func prepareReceiveAcross(_ network: String, _ token: String, _ amount: Decimal, note: String?) async {
        guard let wallet = previewWallet else { return }
        let title = AddressCheck.Network(rawValue: network)?.title ?? network
        do {
            if nearAddress == nil { nearAddress = try await SignerClient().send(.nearAddress).nearAddress }
            guard let account = nearAddress else { throw ExecutionError("The signer has no NEAR account for a refund.") }
            let r = try await executor(wallet).receiveAcross(token, amount: amount, network: network, nearAccount: account)
            acrossDeposit = AcrossDeposit(network: network, token: token.uppercased(), amount: amount, minimum: r.minimum, address: r.deposit,
                                          arrives: r.quote.amountOutFormatted, until: Date().addingTimeInterval(3600))
            withAnimation(StudioView.spring) { detail = "receive-across" }
            reply(say("Send \(Fmt.num(amount)) \(token.uppercased()) on \(title) to the address on the canvas within an hour: ≈ \(r.quote.amountOutFormatted) USDC lands on Solana.",
                      "Отправь \(Fmt.num(amount)) \(token.uppercased()) в сети \(title) на адрес на холсте в течение часа: на Solana придёт ≈ \(r.quote.amountOutFormatted) USDC."),
                  note: note ?? "NEAR Intents · \(title)")
        } catch {
            reply(error.localizedDescription, note: note)
        }
    }
}

/// The address to send to, its QR, what to send (and the least that's taken), what lands on Solana, the deadline, and
/// 1Click's state, asked every 10 s.
struct ReceiveAcrossBoard: View {
    @Environment(Workspace.self) private var ws
    @State private var state = "waiting for your deposit"
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let d = ws.acrossDeposit {
                let title = AddressCheck.Network(rawValue: d.network)?.title ?? d.network
                HStack(spacing: 10) {
                    TokenLogo(name: AddressCheck.Network(rawValue: d.network)?.logo ?? "near", size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Receive \(Fmt.num(d.amount)) \(d.token) from \(title)").font(.ui(16, .bold))
                        Text("through NEAR Intents · lands as ≈ \(d.arrives) USDC on Solana").font(.ui(10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { withAnimation(StudioView.spring) { ws.detail = nil } } label: { Image(systemName: "xmark") }.buttonStyle(.hoverIcon)
                }
                HStack(alignment: .top, spacing: 14) {
                    if let qr = Self.qr(d.address) {
                        Image(nsImage: qr).interpolation(.none).resizable().frame(width: 132, height: 132)
                            .padding(6).background(RoundedRectangle(cornerRadius: 10).fill(.white))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Send \(d.token) on \(title) to").font(.ui(11)).foregroundStyle(.secondary)
                        Text(d.address).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Button(copied ? "Copied" : "Copy address") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(d.address, forType: .string)
                            copied = true
                        }
                        Text("At least \(Fmt.num(d.minimum, maxFraction: 9)) \(d.token), until \(d.until.formatted(date: .omitted, time: .shortened)). Only \(d.token) on \(title) — anything else sent here is lost.")
                            .font(.ui(10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Label("1Click · \(state)", systemImage: "arrow.down.circle").font(.ui(11.5))
                Text("If it can't be swapped, 1Click returns it to your NEAR Intents account, under this wallet's NEAR key.")
                    .font(.ui(10)).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .task(id: ws.acrossDeposit?.address) { await follow() }
    }

    private func follow() async {
        guard let address = ws.acrossDeposit?.address else { return }
        while !Task.isCancelled {
            if let s = try? await OneClick.status(depositAddress: address) {
                state = Executor.oneClickWords[s.status] ?? s.status.lowercased()
                if s.status == "SUCCESS" { state = "done: \(s.amountOutFormatted ?? "?") USDC on Solana"; return }
                if s.isFinal { return }
            }
            try? await Task.sleep(for: .seconds(10))
        }
    }

    static func qr(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: image.extent.width, height: image.extent.height))
    }
}
