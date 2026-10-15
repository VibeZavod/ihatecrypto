import AppKit
import Foundation
import IhatecryptoCore
import Network
import SolanaChain
import WalletCore

/// «From a browser wallet»: a page this Mac serves to its own browser, where Phantom, Solflare, Backpack, MetaMask,
/// Rabby or another extension sends the top-up to this wallet. It is served by the app (127.0.0.1, a new random path
/// each time), so the recipient comes from here and no website in between can swap it. A Solana transfer is built here
/// for the account the page connects (the wallet signs and sends it); an EVM one the page makes from this order.
@Observable @MainActor
final class TopUpPage {
    static let shared = TopUpPage()
    /// What the page said was sent, for the order it served: a Solana signature or an EVM hash.
    private(set) var sent: (order: TopUpOrder, id: String)?
    /// The page being served, for the debug API's /state.
    @ObservationIgnored private(set) var url: URL?
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var port: UInt16 = 0
    @ObservationIgnored private var secret = ""
    @ObservationIgnored private var order: TopUpOrder?

    /// Serves a page for `order` at a new address and returns it; a page opened before stops working.
    func open(_ order: TopUpOrder) async throws -> URL {
        if listener == nil {
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .loopback   // nothing from the network reaches it
            let listener = try NWListener(using: parameters, on: .any)
            listener.newConnectionHandler = { connection in
                connection.start(queue: .main)
                Self.read(connection, Data())
            }
            listener.start(queue: .main)
            // The system picks the port once the listener is ready; until then it reads 0.
            for _ in 0..<100 where (listener.port?.rawValue ?? 0) == 0 { try await Task.sleep(for: .milliseconds(20)) }
            guard let port = listener.port?.rawValue, port != 0 else { listener.cancel(); throw WalletError("The page couldn't start") }
            (self.listener, self.port) = (listener, port)
        }
        self.order = order
        sent = nil
        secret = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        url = URL(string: "http://127.0.0.1:\(port)/\(secret)")!
        return url!
    }

    func stop() {
        listener?.cancel()
        (listener, order, secret, url) = (nil, nil, "", nil)
    }

    private nonisolated static func read(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, done, error in
            let all = buffer + (data ?? Data())
            if let request = DebugAPI.Request(all) {
                Task { @MainActor in
                    let (status, type, body) = await TopUpPage.shared.handle(request)
                    let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
                        + "Cache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Frame-Options: DENY\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
                }
            } else if done || error != nil || all.count > 1 << 16 {
                connection.cancel()
            } else {
                read(connection, all)
            }
        }
    }

    private func handle(_ r: DebugAPI.Request) async -> (Int, String, Data) {
        func text(_ status: Int, _ s: String) -> (Int, String, Data) { (status, "text/plain; charset=utf-8", Data(s.utf8)) }
        let me = "127.0.0.1:\(port)", root = "/" + secret
        // Only this page: its address in Host (a name pointed at 127.0.0.1 shows another), its own origin on a POST.
        guard let order, !secret.isEmpty, r.headers["host"] == me, r.method == "GET" || r.headers["origin"] == "http://\(me)" else {
            return text(403, "This page has closed: open it again from ihatecrypto.")
        }
        let body = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any]
        switch (r.method, r.path) {
        case ("GET", root):
            return (200, "text/html; charset=utf-8", Data(Self.page(order, root: root).utf8))
        case ("GET", root + "/icon.png"):
            let icon = NSApp.applicationIconImage.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
            return (200, "image/png", icon ?? Data())
        case ("GET", root + "/onest.ttf"):
            return (200, "font/ttf", Bundle.main.url(forResource: "Onest", withExtension: "ttf").flatMap { try? Data(contentsOf: $0) } ?? Data())
        case ("POST", root + "/solana"):
            guard order.network.chainId == nil, let from = body?["from"] as? String, isSolanaAddress(from) else { return text(400, "No Solana account") }
            do {
                let wire = try await Self.solanaTransfer(order, from: from)
                return (200, "application/json", (try? JSONSerialization.data(withJSONObject: ["transaction": wire.base64EncodedString()])) ?? Data())
            } catch {
                return text(502, (error as? WalletError)?.message ?? error.localizedDescription)
            }
        case ("POST", root + "/sent"):
            guard let id = body?["id"] as? String, id.wholeMatch(of: /0x[0-9a-fA-F]{64}|[1-9A-HJ-NP-Za-km-z]{64,90}/) != nil else { return text(400, "No transfer id") }
            sent = (order, id)
            return (200, "application/json", Data("{}".utf8))
        default:
            return text(404, "Not here")
        }
    }

    /// The transfer as the connected wallet will sign it: `from` pays the fee, USDC goes by TransferChecked into this
    /// wallet's account (made if missing), SOL by a system transfer.
    nonisolated static func solanaTransfer(_ order: TopUpOrder, from: String) async throws -> Data {
        guard let units = order.units.flatMap(UInt64.init) else { throw WalletError("No amount to send") }
        let blockhash = try await SolanaRPC().latestBlockhash().blockhash
        if order.coin == .native {
            let transfer = SolanaInstruction(program: "11111111111111111111111111111111",
                                             accounts: [.init(pubkey: from, isSigner: true, isWritable: true), .init(pubkey: order.recipient, isSigner: false, isWritable: true)],
                                             data: withUnsafeBytes(of: UInt32(2).littleEndian) { Data($0) } + withUnsafeBytes(of: units.littleEndian) { Data($0) })
            return SolanaTransaction.unsigned(try SolanaTransaction.compileMessage([transfer], payer: from, blockhash: blockhash))
        }
        return SolanaTransaction.unsigned(try SPL.transferMessage(payer: from, to: order.recipient, mint: order.network.usdc, amount: units, decimals: 6, blockhash: blockhash))
    }

    /// The page: the order, the wallets this browser has (Wallet Standard for Solana, EIP-6963 for EVM), one button each.
    private static func page(_ order: TopUpOrder, root: String) -> String {
        let ends = AddressCheck.ends(order.recipient)
        let net = order.network
        // An EVM wallet is switched to the network, or told about it first (wallet_addEthereumChain) when it doesn't know it.
        let chain: [String: Any] = net.chainId.map { id in
            ["chainId": "0x" + String(id, radix: 16), "chainName": net.title, "rpcUrls": [net.rpc], "blockExplorerUrls": [net.explorer],
             "nativeCurrency": ["name": net.coin ?? "USD", "symbol": net.coin ?? "USD", "decimals": 18]]
        } ?? [:]
        let config: [String: Any] = [
            "solana": net.chainId == nil, "chain": chain, "recipient": order.recipient, "units": order.units ?? "0",
            "token": net.chainId != nil && order.coin == .usdc ? net.usdc : "",
            "explorer": order.explorer("").map(\.absoluteString) ?? "",
        ]
        let json = (try? JSONSerialization.data(withJSONObject: config)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return pageHTML
            .replacing("{{amount}}", with: order.amount.map { "\($0)" } ?? "")
            .replacing("{{symbol}}", with: order.symbol)
            .replacing("{{network}}", with: net.title)
            .replacing("{{cost}}", with: net.cost)
            .replacing("{{start}}", with: ends.start).replacing("{{end}}", with: ends.end)
            .replacing("{{recipient}}", with: order.recipient)
            .replacing("{{wallets}}", with: net.chainId == nil ? "Phantom, Solflare or Backpack" : "MetaMask, Rabby, Phantom or Coinbase Wallet")
            .replacing("{{config}}", with: json)
            .replacing("{{root}}", with: root)
    }

    private static let pageHTML = #"""
    <!doctype html>
    <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Top up ihatecrypto</title><link rel="icon" href="{{root}}/icon.png">
    <style>
    @font-face{font-family:Onest;src:url({{root}}/onest.ttf) format("truetype");font-weight:100 900}
    :root{--bg:#0d0e11;--card:#18191d;--line:#2a2b31;--text:#f4f4f5;--dim:#9a9ba3;--accent:#ff7a2f;--ok:#4ade80;--bad:#f87171}
    @media (prefers-color-scheme:light){:root{--bg:#f3f3f1;--card:#fff;--line:#e4e4e1;--text:#141417;--dim:#6b6c72;--ok:#16a34a;--bad:#dc2626}}
    *{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;background:var(--bg);color:var(--text);font:15px/1.45 Onest,-apple-system,system-ui,sans-serif;padding:24px 16px}
    main{width:min(440px,100%);background:var(--card);border:1px solid var(--line);border-radius:26px;padding:26px}
    header{display:flex;align-items:center;gap:10px;font-weight:700;font-size:16px}header img{width:30px;height:30px;border-radius:8px}
    .amount{font-size:38px;font-weight:800;letter-spacing:-.02em;margin:22px 0 2px}.dim{color:var(--dim)}
    .to{margin:16px 0;padding:12px 14px;border-radius:14px;background:var(--bg);font-size:13px}
    .to b{font:600 15px ui-monospace,Menlo,monospace}.to code{display:block;margin-top:4px;font-size:11px;color:var(--dim);word-break:break-all}
    h2{font-size:11px;letter-spacing:.12em;text-transform:uppercase;color:var(--dim);margin:20px 0 8px;font-weight:600}
    button{all:unset;box-sizing:border-box;display:flex;align-items:center;gap:12px;width:100%;padding:12px 14px;margin-bottom:8px;border:1.5px solid var(--line);border-radius:14px;cursor:pointer;font-weight:600}
    button:hover:not(:disabled){border-color:var(--accent)}button:disabled{opacity:.45;cursor:default}button img{width:28px;height:28px;border-radius:7px}
    button span{flex:1}button i{font-style:normal;color:var(--dim)}
    #status{min-height:22px;font-size:14px;margin-top:6px}#status.ok{color:var(--ok)}#status.bad{color:var(--bad)}#status a{color:inherit}
    footer{margin-top:18px;font-size:12px;color:var(--dim)}
    </style></head><body><main>
    <header><img src="{{root}}/icon.png" alt="">Top up ihatecrypto</header>
    <div class="amount">{{amount}} {{symbol}}</div><div class="dim">on {{network}} · {{cost}}</div>
    <div class="to">To your ihatecrypto wallet <b>{{start}} … {{end}}</b><code>{{recipient}}</code></div>
    <h2>Top up from</h2><div id="wallets"></div>
    <div id="none" class="dim" hidden>No wallet found in this browser. Install {{wallets}}, or scan the QR in ihatecrypto with your phone.</div>
    <div id="status"></div>
    <footer>This page comes from ihatecrypto on your Mac, not from a website: the address above can't be swapped. Your wallet shows the transfer before you approve it.</footer>
    </main><script>
    const C = {{config}};
    const list = document.getElementById('wallets'), statusLine = document.getElementById('status'), seen = new Set();
    const say = (html, kind) => { statusLine.innerHTML = html; statusLine.className = kind || ''; };
    const post = async (what, body) => {
      const r = await fetch(location.pathname + '/' + what, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
      if (!r.ok) throw new Error(await r.text());
      return r.json();
    };
    const B58 = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
    const base58 = bytes => {
      let n = 0n, s = '';
      for (const b of bytes) n = n * 256n + BigInt(b);
      while (n > 0n) { s = B58[Number(n % 58n)] + s; n /= 58n; }
      for (const b of bytes) { if (b) break; s = '1' + s; }
      return s;
    };
    function wallet(name, icon, pay) {
      if (seen.has(name)) return;
      seen.add(name);
      document.getElementById('none').hidden = true;
      const b = document.createElement('button');
      b.innerHTML = (icon ? '<img alt="">' : '') + '<span></span><i>→</i>';
      if (icon) b.querySelector('img').src = icon;
      b.querySelector('span').textContent = name;
      b.onclick = async () => {
        for (const x of list.children) x.disabled = true;
        try {
          say('Connecting ' + name + '…');
          const id = await pay(() => say('Approve the transfer in ' + name + '…'));
          // Sent is sent: a closed page (the card was closed meanwhile) only means ihatecrypto learns it from the balance.
          await post('sent', { id }).catch(() => {});
          say('Sent ✓ ihatecrypto shows it the moment it lands. You can close this tab. <a target="_blank" rel="noreferrer" href="' + C.explorer + id + '">See it ↗</a>', 'ok');
        } catch (e) {
          const no = e && (e.code === 4001 || /reject|denied|cancel|declined/i.test(e.message || ''));
          say(no ? 'Cancelled in the wallet. Nothing was sent.' : 'It didn’t go through: ' + ((e && e.message) || e), 'bad');
          for (const x of list.children) x.disabled = false;
        }
      };
      list.append(b);
    }
    if (C.solana) {
      // Wallet Standard: wallets register when the page says it's ready, or announce themselves when they load later.
      const api = { register: (...ws) => { ws.forEach(solana); return () => {}; } };
      window.addEventListener('wallet-standard:register-wallet', e => e.detail(api));
      window.dispatchEvent(new CustomEvent('wallet-standard:app-ready', { detail: api }));
      function solana(w) {
        const f = w.features || {};
        if (!f['standard:connect'] || !f['solana:signAndSendTransaction'] || !(w.chains || []).includes('solana:mainnet')) return;
        wallet(w.name, w.icon, async approve => {
          const { accounts } = await f['standard:connect'].connect();
          const account = accounts[0] || w.accounts[0];
          const { transaction } = await post('solana', { from: account.address });
          approve();
          const bytes = Uint8Array.from(atob(transaction), c => c.charCodeAt(0));
          const [out] = await f['solana:signAndSendTransaction'].signAndSendTransaction({ account, chain: 'solana:mainnet', transaction: bytes });
          return base58(out.signature);
        });
      }
    } else {
      // EIP-6963: every EVM wallet announces itself; window.ethereum is the fallback for an older one.
      window.addEventListener('eip6963:announceProvider', e => evm(e.detail.info.name, e.detail.info.icon, e.detail.provider));
      window.dispatchEvent(new Event('eip6963:requestProvider'));
      setTimeout(() => { if (!seen.size && window.ethereum) evm('Browser wallet', '', window.ethereum); }, 800);
      function evm(name, icon, p) {
        wallet(name, icon, async approve => {
          const [from] = await p.request({ method: 'eth_requestAccounts' });
          try { await p.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: C.chain.chainId }] }); }
          catch (e) {
            if (e.code !== 4902) throw e;
            await p.request({ method: 'wallet_addEthereumChain', params: [C.chain] });
          }
          approve();
          const amount = BigInt(C.units).toString(16);
          const tx = C.token
            ? { from, to: C.token, data: '0xa9059cbb' + C.recipient.slice(2).toLowerCase().padStart(64, '0') + amount.padStart(64, '0') }
            : { from, to: C.recipient, value: '0x' + amount };
          return await p.request({ method: 'eth_sendTransaction', params: [tx] });
        });
      }
    }
    setTimeout(() => { if (!seen.size) document.getElementById('none').hidden = false; }, 1500);
    </script></body></html>
    """#
}
