/// Injected into every page's main frame before its own scripts: registers LALA as a Solana wallet through the
/// Wallet Standard (the events wallet adapters listen for). Every call goes to the app, which asks the user.
enum ProviderScript {
    static let source = #"""
    (() => {
      if (window.__lalaWallet) return;
      const call = (method, params) => window.webkit.messageHandlers.lala.postMessage({ method, params });
      const toB64 = (bytes) => { let s = ''; for (const b of bytes) s += String.fromCharCode(b); return btoa(s); };
      const fromB64 = (text) => Uint8Array.from(atob(text), (c) => c.charCodeAt(0));
      const listeners = { change: [] };
      let accounts = [];
      const features = ['solana:signTransaction', 'solana:signAndSendTransaction', 'solana:signMessage'];
      const setAccount = (r) => {
        accounts = r && r.address ? [{ address: r.address, publicKey: fromB64(r.publicKey), chains: ['solana:mainnet'], features, label: 'LALA' }] : [];
        (listeners.change || []).forEach((f) => f({ accounts }));
      };
      const each = async (inputs, fn) => { const out = []; for (const input of inputs) out.push(await fn(input)); return out; };
      const wallet = {
        version: '1.0.0',
        name: 'LALA',
        icon: 'data:image/svg+xml;base64,' + btoa('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect width="32" height="32" rx="8" fill="#2c4f86"/><text x="16" y="22" font-size="18" font-family="Georgia" font-style="italic" fill="#eef8ff" text-anchor="middle">l</text></svg>'),
        chains: ['solana:mainnet'],
        get accounts() { return accounts; },
        features: {
          'standard:connect': { version: '1.0.0', connect: async (input) => { setAccount(await call('connect', { silent: !!(input && input.silent) })); return { accounts }; } },
          'standard:disconnect': { version: '1.0.0', disconnect: async () => { await call('disconnect', {}); setAccount(null); } },
          'standard:events': { version: '1.0.0', on: (event, listener) => { (listeners[event] = listeners[event] || []).push(listener); return () => { listeners[event] = listeners[event].filter((l) => l !== listener); }; } },
          'solana:signTransaction': { version: '1.0.0', supportedTransactionVersions: ['legacy', 0],
            signTransaction: (...inputs) => each(inputs, async (i) => ({ signedTransaction: fromB64((await call('signTransaction', { transaction: toB64(i.transaction) })).signed) })) },
          'solana:signAndSendTransaction': { version: '1.0.0', supportedTransactionVersions: ['legacy', 0],
            signAndSendTransaction: (...inputs) => each(inputs, async (i) => ({ signature: fromB64((await call('signAndSendTransaction', { transaction: toB64(i.transaction) })).signature) })) },
          'solana:signMessage': { version: '1.0.0',
            signMessage: (...inputs) => each(inputs, async (i) => ({ signedMessage: i.message, signature: fromB64((await call('signMessage', { message: toB64(i.message) })).signature) })) },
        },
      };
      let registrations = 0;
      const register = ({ register }) => { registrations += 1; return register(wallet); };
      try { window.dispatchEvent(new CustomEvent('wallet-standard:register-wallet', { detail: register })); } catch (e) {}
      try { window.addEventListener('wallet-standard:app-ready', ({ detail }) => register(detail)); } catch (e) {}
      // The older path some wallet adapters still read, as Phantom's own registration keeps it too.
      try { (window.navigator.wallets = window.navigator.wallets || []).push(register); } catch (e) {}
      Object.defineProperty(window, '__lalaRegistrations', { get: () => registrations });

      // EVM: an EIP-1193 provider, announced through EIP-6963 so sites list «LALA» beside other wallets.
      // Errors come back as "code|message" and are rethrown with the EIP-1193 code (4001 refused, 4200 unsupported).
      const ethListeners = {};
      const ethEmit = (event, value) => (ethListeners[event] || []).forEach((f) => { try { f(value); } catch (e) {} });
      const ethCall = async (method, params) => {
        try {
          const r = await call('eth', { method, params: JSON.stringify(params === undefined ? [] : params) });
          return r === null || r === undefined ? null : JSON.parse(r);
        } catch (e) {
          const text = String((e && e.message) || e);
          const bar = text.indexOf('|');
          const error = new Error(bar > 0 ? text.slice(bar + 1) : text);
          error.code = bar > 0 ? Number(text.slice(0, bar)) : 4001;
          throw error;
        }
      };
      const ethereum = {
        isLALA: true,
        request: async ({ method, params }) => {
          const result = await ethCall(method, params);
          if (method === 'eth_requestAccounts') ethEmit('accountsChanged', result);
          if (method === 'wallet_switchEthereumChain') ethEmit('chainChanged', await ethCall('eth_chainId', []));
          return result;
        },
        on: (event, f) => { (ethListeners[event] = ethListeners[event] || []).push(f); return ethereum; },
        removeListener: (event, f) => { ethListeners[event] = (ethListeners[event] || []).filter((x) => x !== f); return ethereum; },
      };
      const info = Object.freeze({ uuid: (crypto.randomUUID && crypto.randomUUID()) || String(Math.random()), name: 'LALA', icon: wallet.icon, rdns: 'app.lala' });
      const announce = () => window.dispatchEvent(new CustomEvent('eip6963:announceProvider', { detail: Object.freeze({ info, provider: ethereum }) }));
      window.addEventListener('eip6963:requestProvider', announce);
      announce();
      if (!window.ethereum) { try { Object.defineProperty(window, 'ethereum', { value: ethereum, configurable: true }); } catch (e) {} }
      Object.defineProperty(window, '__lalaWallet', { value: wallet });
    })();
    """#
}
