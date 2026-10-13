#!/usr/bin/env python3
"""Labelled plans and signature lists in the app's own wording (Workspace.planLines, Executor.prepare), right ones and
ones with one thing changed. usage: plans.py plan|tx > cases.jsonl"""
import copy, json, sys

PRICE = {"ETH": 2680, "BTC": 84000, "SOL": 152.4, "oil": 71.35, "gold": 2655, "TSLA": 412.5, "HYPE": 38.2}
RU = {"ETH": "эфир", "BTC": "биток", "SOL": "солану", "oil": "нефть", "gold": "золото", "TSLA": "теслу", "HYPE": "хайп"}
ES = {"ETH": "ether", "BTC": "bitcoin", "SOL": "solana", "oil": "petróleo", "gold": "oro", "TSLA": "Tesla", "HYPE": "HYPE"}

def num(x, d=6):
    s = f"{x:,.{d}f}".rstrip("0").rstrip(".")
    return s or "0"
def usd(x): return "$" + f"{x:,.2f}"
def price(x): return num(x, 0 if x >= 1000 else 2)

class Plan:
    """What the user asked (asked_*) and what the plan does. money = margin put in; risk = loss at the stop."""
    def __init__(self, asset, side, lev, stop, take=None, money=None, risk=None, rules=()):
        self.asset, self.side, self.lev, self.stop, self.take, self.rules = asset, side, lev, stop, take, list(rules)
        p = PRICE[asset]
        if money is not None:
            self.margin = money; self.notional = money * lev; self.loss = self.notional * stop / 100
        else:
            self.loss = risk; self.notional = risk / (stop / 100); self.margin = self.notional / lev
        self.size = self.notional / p
    def lines(self):
        p = PRICE[self.asset]; sign = -1 if self.side == "long" else 1
        out = [f"{self.side.capitalize()} {self.asset} on Hyperliquid, leverage {num(self.lev)}×.",
               f"Size {num(self.size)} {self.asset} at ≈ {price(p)}, notional {usd(self.notional)}, margin {usd(self.margin)}.",
               f"Stop {num(self.stop)}% → {price(p * (1 + sign * self.stop / 100))}, loss ≈ {usd(self.loss)} (risk {usd(self.loss)})."]
        if self.take: out.append(f"Take-profit {num(self.take)}% → {price(p * (1 - sign * self.take / 100))}, profit ≈ {usd(self.notional * self.take / 100)}.")
        if self.rules: out.append("The user asked to fill in the rest by the rules: " + " ".join(self.rules))
        out.append(f"Move {num(self.margin, 2)} USDC from Solana to Hyperliquid.")
        return out
    def signatures(self, arrive=None, spend=None, to=None):
        spend = spend if spend is not None else round(self.margin * 1.004 + 0.02, 2); arrive = arrive if arrive is not None else round(self.margin, 2)
        p = PRICE[self.asset]; worst = p * (1.01 if self.side == "long" else 0.99)
        first = (f"Relay bridge: {num(spend, 2)} USDC from Solana → {num(arrive, 2)} USDC on Hyperliquid, fee {usd(spend - arrive)}." if to is None
                 else f"Transfer {num(spend, 2)} USDC from Solana to address {to}.")
        steps = [first, f"Leverage {num(self.lev)}×, isolated margin.",
                 f"{self.side.capitalize()} {num(self.size)} {self.asset} at market, no worse than {price(worst)}.",
                 f"Stop {num(self.stop)}%" + (f" and take-profit {num(self.take)}%" if self.take else "") + f" from the entry price ({'stop below, take above' if self.side == 'long' else 'stop above, take below'}), on the exchange."]
        have = round(spend + 31.4, 2)
        changes = [f"Solana USDC: {num(have, 2)} → {num(have - spend, 2)} (−{num(spend, 2)}).",
                   f"Hyperliquid, free: $1.57 → ≈ {usd(1.57 + arrive - self.margin)} (margin {usd(self.margin)} goes into the position).",
                   f"Position: {self.side} {num(self.size)} {self.asset}, at the stop ≈ −{usd(self.loss)}" + (f", at the take ≈ +{usd(self.notional * self.take / 100)}." if self.take else ".")]
        return steps, changes

def rules_notes(lev, stop, take, money=None):
    out = [f"Stop by volatility: 1.5 × 4h ATR ({num(stop / 1.5, 2)}%) ≈ {num(stop)}%.", f"Take-profit 2R: 2 × stop = {num(take)}%.",
           f"Leverage {num(lev)}×, the rules' cap; the stop sets the loss, leverage only shrinks the margin."]
    if money: out.append(f"{num(money)} USDC in the trade at {num(lev)}× with a {num(stop)}% stop risks {usd(money * lev * stop / 100)}.")
    return out

REQUESTS = []   # (lang, [messages], Plan kwargs)
for asset, side, money in [("oil", "long", 5), ("ETH", "long", 10), ("gold", "short", 20), ("TSLA", "long", 3), ("SOL", "short", 15), ("BTC", "long", 50), ("HYPE", "long", 8)]:
    kw = dict(asset=asset, side=side, lev=5, stop=1.8, take=3.6, money=money, rules=rules_notes(5, 1.8, 3.6, money))
    ru_side = "лонг" if side == "long" else "шорт"
    REQUESTS += [("ru", [f"{ru_side} {RU[asset]} на {money}$"], kw), ("en", [f"{side} {asset} with {money} bucks"], kw),
                 ("es", [f"abre un {side} de {ES[asset]} con {money} dólares"], kw)]
for asset, side, risk, stop, take, lev in [("ETH", "long", 1, 3, 6, 3), ("gold", "short", 2, 1.5, 3, 4), ("BTC", "short", 5, 2, 4, 2), ("SOL", "long", 0.5, 4, 8, 5), ("oil", "long", 3, 2.5, 5, 3)]:
    kw = dict(asset=asset, side=side, lev=lev, stop=stop, take=take, risk=risk)
    REQUESTS += [("en", [f"{side} {asset} risk ${risk} stop {stop}% take {take}% leverage {lev}x"], kw),
                 ("ru", [f"{'лонг' if side == 'long' else 'зашорть'} {RU[asset]}, рискую {risk} бакса, стоп {stop}%, тейк {take}%, плечо {lev}"], kw),
                 ("es", [f"{side} en {ES[asset]} con riesgo de {risk} dólares, stop del {stop}%, take {take}%, apalancamiento {lev}"], kw)]
# edits: the later message changes the plan
for asset, side, money, lev in [("ETH", "long", 10, 3), ("oil", "short", 6, 4), ("SOL", "long", 12, 2)]:
    kw = dict(asset=asset, side=side, lev=lev, stop=2, take=4, money=money)
    REQUESTS += [("ru", [f"{'лонг' if side == 'long' else 'шорт'} {RU[asset]} на 4 бакса стоп 2% тейк 4%", f"давай на {money} и плечо {lev}"], kw),
                 ("en", [f"{side} {asset} 4 USDC stop 2% take 4%", f"make it {money} USDC, leverage {lev}x"], kw)]

def variants(kw):
    """(kind, kwargs) of plans that no longer do what was asked."""
    out = []
    def changed(kind, **over): k = dict(kw, **over); out.append((kind, k))
    changed("side", side="short" if kw["side"] == "long" else "long")
    changed("asset", asset="BTC" if kw["asset"] != "BTC" else "ETH")
    if kw.get("money") is not None:
        changed("amount_x10", money=kw["money"] * 10, rules=[])
        k = dict(kw); k.pop("money"); k["risk"] = kw["money"]; k["rules"] = []; out.append(("role", k))      # «на 5$» taken as risk $5
    else:
        changed("amount_x10", risk=kw["risk"] * 10)
        k = dict(kw); k.pop("risk"); k["money"] = kw["risk"]; out.append(("role", k))                           # «risk $1» taken as 1 USDC in the trade
    if not kw.get("rules"):
        changed("stop", stop=kw["stop"] * 3)
        changed("leverage", lev=kw["lev"] * 4)
    return out

mode = sys.argv[1]; n = 0
for lang, msgs, kw in REQUESTS:
    good = Plan(**kw)
    if mode == "plan":
        print(json.dumps({"id": n, "kind": "plan", "lang": lang, "requests": msgs, "plan": good.lines(), "label": "match", "mutation": "", "name": msgs[-1]}, ensure_ascii=False)); n += 1
        for kind, k in variants(kw):
            print(json.dumps({"id": n, "kind": "plan", "lang": lang, "requests": msgs, "plan": Plan(**k).lines(), "label": "mismatch", "mutation": kind, "name": msgs[-1]}, ensure_ascii=False)); n += 1
    elif lang == "en" or len(msgs) > 1:   # signatures don't depend on the user's language
        spend = round(good.margin * 1.004 + 0.02, 2)
        def emit(label, kind, plan_obj, **sig):
            global n
            steps, changes = plan_obj.signatures(**sig)
            print(json.dumps({"id": n, "kind": "tx", "plan": good.lines(), "signatures": steps, "changes": changes, "label": label, "mutation": kind,
                              "name": good.lines()[0] + " / " + steps[0]}, ensure_ascii=False)); n += 1
        emit("match", "", good)
        emit("match", "", good, arrive=round(spend * 0.985, 2))               # the bridge quoted again: a little less arrives
        emit("match", "", good, spend=round(spend * 1.03, 2))                 # … or costs a little more
        emit("mismatch", "foreign_address", good, to="9xQeWvG816bUx9EPjHmaT23yvVM2ZWbrrpZb9PusVFin")
        emit("mismatch", "amount_x10", good, spend=spend * 10)
        emit("mismatch", "amount_x2", good, spend=spend * 2)
        emit("mismatch", "side", Plan(**dict(kw, side="short" if kw["side"] == "long" else "long")))
        emit("mismatch", "asset", Plan(**dict(kw, asset="BTC" if kw["asset"] != "BTC" else "ETH")))
        emit("mismatch", "leverage", Plan(**dict(kw, lev=kw["lev"] * 4)))
        big = dict(kw); big["money" if kw.get("money") is not None else "risk"] = (kw.get("money") or kw.get("risk")) * 10
        emit("mismatch", "size_x10", Plan(**big), spend=spend)
