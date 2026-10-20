#!/usr/bin/env python3
"""Fills Sources/IhatecryptoApp/Logos with the logos of the top N coins by market cap (CoinGecko), named by ticker
(«btc.png»), 128 px. Files already there stay as they are; of two coins sharing a ticker the bigger one wins.
The app shows them by ticker (TokenLogo.name(forAsset:), HoldingIcon) where no icon comes with the token.

Run from App/:  python3 Tools/top-logos.py [N=300]   then rebuild (build-app.sh regenerates the Xcode project)."""
import json, os, re, subprocess, sys, tempfile, time, urllib.request

N = int(sys.argv[1]) if len(sys.argv) > 1 else 300
LOGOS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Sources", "IhatecryptoApp", "Logos")
HEADERS = {"User-Agent": "Mozilla/5.0", "Accept": "application/json"}


def get(url):
    for attempt in range(4):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=HEADERS), timeout=30) as r:
                return r.read()
        except Exception:
            if attempt == 3:
                raise
            time.sleep(20)  # the public API allows a few calls a minute


def main():
    coins = []
    for page in range(1, (N + 249) // 250 + 1):
        coins += json.loads(get("https://api.coingecko.com/api/v3/coins/markets"
                                f"?vs_currency=usd&order=market_cap_desc&per_page=250&page={page}"))
    have = {os.path.splitext(f)[0] for f in os.listdir(LOGOS)}
    added, skipped = [], []
    with tempfile.TemporaryDirectory() as tmp:
        for c in coins[:N]:
            # The same file on CoinGecko's older host: coin-images.coingecko.com doesn't answer from every network.
            ticker = c["symbol"].lower()
            image = (c.get("image") or "").replace("coin-images.coingecko.com", "assets.coingecko.com")
            if ticker in have:
                continue
            have.add(ticker)
            # A file name the bundle can look up; CoinGecko's «missing» picture is no logo.
            if not re.fullmatch(r"[a-z0-9]+", ticker) or "missing" in image:
                skipped.append(ticker)
                continue
            raw = os.path.join(tmp, ticker)
            try:
                with open(raw, "wb") as f:
                    f.write(get(image))
                subprocess.run(["sips", "-s", "format", "png", "-Z", "128", raw, "--out", os.path.join(LOGOS, ticker + ".png")],
                               check=True, capture_output=True)
                added.append(ticker)
            except Exception as e:
                skipped.append(f"{ticker} ({e})")
    print(f"top {N}: added {len(added)}: {' '.join(added)}")
    if skipped:
        print(f"skipped {len(skipped)}: {' '.join(skipped)}")


if __name__ == "__main__":
    main()
