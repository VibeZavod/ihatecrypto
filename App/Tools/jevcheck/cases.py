#!/usr/bin/env python3
"""Labelled cases for the second reading (JevReviewer.reading): the (message, command) pairs a router run got right
(routecheck's results: ru/en/es, slang, typos), each also with one thing in the command changed — the opposite action,
another asset, network, place or recipient, an amount ×10 or +20%, money as risk — so it no longer does what was asked.

    python3 cases.py ../routecheck/results-random.jsonl > reading.jsonl          # 222 right, 688 wrong (kept here: the results aren't in git)
    OPENROUTER_API_KEY=… swift run WalletCheck jev-eval reading.jsonl > verdicts.jsonl
    python3 score.py reading.jsonl verdicts.jsonl

followups.jsonl is a second set made the same way from follow-ups in a conversation (recent chat and the canvas given);
plans.py makes the plans and the signature lists; site.jsonl and screen.jsonl are small hand-written ones."""
import json, re, sys

SRC = sys.argv[1]
rows = [json.loads(l) for l in open(SRC) if l.strip()]
ok = [r for r in rows if r["ok"] and r["out"].get("route") == "command" and r["out"].get("command")]

FLIPS = [("long", "short"), ("buy", "sell"), ("deposit", "withdraw"), ("stake", "unstake"), ("above", "below")]
ASSETS = {"ETH": "BTC", "BTC": "ETH", "SOL": "ETH", "oil": "gold", "gold": "oil", "JUP": "BONK", "WIF": "BONK", "BONK": "WIF", "OP": "ARB",
          "DEGEN": "BRETT", "TSLA": "NVDA", "NVDA": "TSLA", "PEPE": "DOGE", "NEAR": "SOL", "JitoSOL": "mSOL", "HYPE": "SOL", "AAPL": "TSLA"}
NETS = ["base", "arbitrum", "optimism", "polygon", "ethereum", "solana", "robinhood", "hyperliquid", "tempo", "hyperevm", "bnb"]
PLACES = {"kamino": "HLP", "HLP": "kamino", "Aave": "Morpho", "Morpho": "Aave"}
PEOPLE = {"Mom": "Bybit", "Bybit": "Mom"}
NUM = r"(?<![\w.$])(\d+(?:\.\d+)?)(?= (?:USDC|USDG|SOL|[A-Za-z]{2,8}\b))"


def fmt(x):
    return f"{x:.6f}".rstrip("0").rstrip(".")


def mutations(cmd):
    out = []
    def word(a, b, kind):
        if re.search(rf"\b{a}\b", cmd):
            out.append((kind, re.sub(rf"\b{a}\b", b, cmd, count=1)))
            return True
        return False
    for a, b in FLIPS:
        word(a, b, "flip") or word(b, a, "flip")
    m = re.search(r"from (\w+) to (\w+)", cmd)
    if m:
        out.append(("direction", cmd.replace(m.group(0), f"from {m.group(2)} to {m.group(1)}", 1)))
    m = re.search(NUM, cmd) or re.search(r"(?<=\$)(\d+(?:\.\d+)?)", cmd)
    if m:
        n = float(m.group(1))
        out.append(("amount_x10", cmd[:m.start(1)] + fmt(n * 10) + cmd[m.end(1):]))
        out.append(("amount_near", cmd[:m.start(1)] + fmt(n * 1.2) + cmd[m.end(1):]))
    for a, b in ASSETS.items():
        if word(a, b, "asset"):
            break
    low = cmd.lower()
    present = [n for n in NETS if re.search(rf"\b{n}\b", low)]
    if present:
        other = next(n for n in NETS if n not in present)
        out.append(("network", re.sub(rf"\b{present[0]}\b", other.capitalize(), cmd, count=1, flags=re.I)))
    for a, b in PLACES.items():
        if word(a, b, "place"):
            break
    for a, b in PEOPLE.items():
        if word(a, b, "recipient"):
            break
    if re.match(r"(long|short) ", cmd):
        m = re.search(r"(\d+(?:\.\d+)?) USDC", cmd)
        r = re.search(r"risk \$(\d+(?:\.\d+)?)", cmd)
        if m:
            out.append(("role", cmd.replace(m.group(0), f"risk ${m.group(1)}", 1)))
        elif r:
            out.append(("role", cmd.replace(r.group(0), f"{r.group(1)} USDC", 1)))
    return [(k, c) for k, c in out if c != cmd]


n = 0
for r in ok:
    base = {"lang": r["lang"], "kind": r["kind"], "message": r["message"]}
    print(json.dumps({**base, "id": n, "command": r["out"]["command"], "label": "match", "mutation": ""}, ensure_ascii=False)); n += 1
    for kind, cmd in mutations(r["out"]["command"]):
        print(json.dumps({**base, "id": n, "command": cmd, "label": "mismatch", "mutation": kind}, ensure_ascii=False)); n += 1
