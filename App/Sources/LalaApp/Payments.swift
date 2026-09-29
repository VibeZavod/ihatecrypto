import EVMChain
import Foundation
import LalaCore
import TradeExecution
import WalletCore

/// «pay POST https://… {…}»: a paid API on Tempo (MPP). The request goes out once unpaid; the service's 402 names the
/// price and the payee, which the card shows. After Confirm ihatecrypto pays that USDC on Tempo itself (the signer checks
/// the payee as a new recipient) and sends the request again with the transaction's hash as the proof.
extension Workspace {
    func preparePayment(_ command: WalletCommand, note: String? = nil) async {
        guard case .pay(let method, let url, let body) = command, let host = URL(string: url)?.host() else {
            reply(say("That isn't a web address ihatecrypto can call.", "Это не веб-адрес, который ihatecrypto может вызвать."), note: note)
            return
        }
        agentStep = say("Asking \(host) for its price", "Спрашиваю цену у \(host)")
        do {
            let (status, headers, data) = try await MPP.call(method, url, body)
            guard status == 402 else {
                reply((200..<300).contains(status) ? say("\(host) answered for free:\n", "\(host) ответил бесплатно:\n") + MPP.shown(data)
                                                   : say("\(host) answered \(status): ", "\(host) ответил \(status): ") + MPP.shown(data, limit: 300), note: note)
                return
            }
            switch MPP.challenge(headers["www-authenticate"] ?? "") {
            case .failure(let refusal):
                reply(say("Can't pay \(host): ", "Не могу оплатить \(host): ") + refusal.reason, note: note)
            case .success(let c):
                payment = (command, c)
                pendingAction = .wallet(command)
                pendingText = "pay \(Fmt.num(c.usdc, maxFraction: 6)) USDC to \(host)"
                reply(say("\(host) asks \(Fmt.num(c.usdc, maxFraction: 6)) USDC\(c.purpose.map { " for «\($0)»" } ?? ""). The card is on the canvas — Confirm pays it in USDC on Tempo.",
                          "\(host) просит \(Fmt.num(c.usdc, maxFraction: 6)) USDC\(c.purpose.map { " за «\($0)»" } ?? ""). Карточка на холсте — Confirm оплатит в USDC на Tempo."), note: note)
            }
        } catch {
            reply(say("Couldn't reach \(host): ", "Не достучался до \(host): ") + error.localizedDescription, note: note)
        }
    }

    /// After Confirm: the quoted price paid on Tempo, then the request again with the proof. A quote about to expire is
    /// asked for again, and only the same price to the same payee is paid.
    func pay(_ command: WalletCommand, _ e: Executor) async throws -> String {
        guard case .pay(let method, let url, let body) = command, let quote = payment, quote.command == command else {
            throw ExecutionError("The service's price is gone; ask for it again.")
        }
        var c = quote.challenge
        if let expires = c.expires, expires.timeIntervalSinceNow < 30 {
            let (status, headers, _) = try await MPP.call(method, url, body)
            guard status == 402, case .success(let fresh) = MPP.challenge(headers["www-authenticate"] ?? "") else {
                throw ExecutionError("The service didn't quote again (\(status)); nothing was paid.")
            }
            guard fresh.amount == c.amount, fresh.payee.lowercased() == c.payee.lowercased() else {
                throw ExecutionError("The price changed to \(Fmt.num(fresh.usdc, maxFraction: 6)) USDC; nothing was paid. Ask again to see the new card.")
            }
            c = fresh
        }
        let host = URL(string: url)?.host() ?? c.realm
        let hash = try await e.payTempo(c.amount, to: c.payee, memo: c.memo, label: host)
        payment = nil
        let proof = "\(EVMNetwork.tempo.explorer)/tx/\(hash)"
        let (status, _, data) = try await MPP.call(method, url, body, credential: (c.field, MPP.credential(c, hash: hash, payer: signerWallet?.evm ?? "")))
        guard (200..<300).contains(status) else {
            throw ExecutionError("Paid \(Fmt.num(c.usdc, maxFraction: 6)) USDC, but \(host) answered \(status): \(MPP.shown(data, limit: 300)). The payment is on Tempo: \(proof)")
        }
        return "Paid \(Fmt.num(c.usdc, maxFraction: 6)) USDC to \(host) on Tempo. \(proof)\n\n" + MPP.shown(data)
    }

    /// The card: USDC on Tempo (with what comes from Solana first) → the payment → the service.
    func payRoute(_ command: WalletCommand) -> MoveRoute? {
        guard case .pay(_, let url, _) = command, let c = payment?.challenge, payment?.command == command else { return nil }
        let host = URL(string: url)?.host() ?? c.realm, price = Fmt.num(c.usdc, maxFraction: 6)
        let there = tempoUSDC ?? 0, short = there < c.usdc
        return MoveRoute(title: "Pay \(price) USDC · \(host)",
                         footer: "One Tempo transfer of \(price) USDC to the address \(host) named (\(AddressCheck.ends(c.payee).start) … \(AddressCheck.ends(c.payee).end)); "
                            + (short ? "what's short comes from Solana over Relay first; " : "")
                            + "the fee, ≈ $0.001, comes out of the USDC. Then the request goes again with the payment's hash. Say “do it” or press Confirm.",
                         steps: [
            ActivityBubble(kind: "step", label: short ? "FROM · SOLANA → TEMPO" : "FROM · TEMPO",
                           title: "\(Fmt.num(there)) → \(Fmt.num(max(0, there - c.usdc))) USDC", lines: [short ? "bridged over Relay first" : "your USDC on Tempo"],
                           logo: short ? "sol" : "tempo", fill: short ? .solana : .tempo),
            ActivityBubble(kind: "step", label: "PAY · MPP", title: "\(price) USDC", lines: [c.purpose ?? "one request"], logo: "tempo", fill: .tempo),
            ActivityBubble(kind: "step", label: "TO · \(host.uppercased())", title: "the answer comes here", lines: [c.realm], logo: "tempo", fill: .check),
        ])
    }
}
