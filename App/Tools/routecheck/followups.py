#!/usr/bin/env python3
"""Follow-ups in a conversation: a card waiting for Confirm, a plan on the canvas, a question answered — and the next
message, in ru/en/es. Same JSONL as gen_phrases.py, with «env» for LLMCheck (canvas, recent chat, plan, balances)."""
import json, random, sys
rnd = random.Random(11)
SPREAD = ("waiting for Confirm: «spread 500 USDC across the best rates»; its plan (not part of the command): Jupiter Lend 250 USDC at 6.12%, "
          "Kamino 250 USDC at 5.81%, taking Solana's; at most 50% per protocol; ≈ 29.8 USDC a year")
MOVE = ("waiting for Confirm: «move 100 USDC from Base to Solana»; its route (not part of the command): FROM · BASE 100 USDC → "
        "BRIDGE · RELAY fee ≈ $0.02 (~2 s) → TO · SOLANA ≈ 99.98 USDC")
KAMINO = "waiting for Confirm: «deposit 20 USDC to kamino»; its route (not part of the command): FROM · SOLANA 20 USDC → KAMINO · LEND USDC at 5.81%"
BAL = "Solana 1,240 USDC, 0.31 SOL|Base 300 USDC idle|Hyperliquid trading balance $57.20, withdrawable $57.20"
PLAN = json.dumps({"asset": "ETH", "side": "long", "amountUSDC": 10, "leverage": 3, "autoRules": True})
cases = []
def add(env, msgs, expect, kind):
    for lang, m in msgs:
        cases.append({"lang": lang, "kind": kind, "message": m, "expect": expect, "env": env})
def cmd(*r): return {"route": "command", "cmd": ["^" + x + "$" for x in r]}

e = {"IHATECRYPTO_ROUTE_CANVAS": SPREAD, "IHATECRYPTO_ROUTE_BALANCES": BAL,
     "IHATECRYPTO_ROUTE_RECENT": "user: разложи 500 usdc по лучшим ставкам|ihatecrypto: Spread 500 USDC: Jupiter Lend 250 at 6.12%, Kamino 250 at 5.81%. Confirm on the canvas."}
add(e, [("ru", "добавь ещё 300"), ("ru", "и ещё 300 сверху"), ("en", "add 300 more"), ("en", "throw in another 300"), ("es", "añade 300 más")],
    cmd(r"spread 800 usdc(?: from solana)? across the best rates(?: max 50% per protocol)?"), "fu_spread_more")
add(e, [("ru", "а без kamino?"), ("ru", "давай без камино"), ("en", "and without kamino?"), ("en", "skip kamino"), ("es", "¿y sin Kamino?")],
    cmd(r"spread 500 usdc(?: from solana)? across the best rates(?: max 50% per protocol)? without kamino"), "fu_spread_without")
add(e, [("ru", "сделай 200 вместо 500"), ("en", "make it 200 instead"), ("es", "mejor 200 en vez de 500")],
    cmd(r"spread 200 usdc(?: from solana)? across the best rates(?: max 50% per protocol)?"), "fu_spread_resize")
add(e, [("ru", "звучит норм, запускай"), ("ru", "ну всё, погнали"), ("en", "looks good, ship it"), ("en", "lgtm go"), ("es", "vale, adelante")],
    {"route": "confirm"}, "fu_confirm")
add(e, [("ru", "не, забей, ничего не надо"), ("en", "nah forget it"), ("es", "no, déjalo")], {"route": "cancel"}, "fu_cancel")
add(e, [("ru", "это точно лучшие ставки?"), ("ru", "почему не морфо?"), ("en", "are these really the best rates?"), ("en", "why not morpho?"),
        ("es", "¿seguro que son las mejores tasas?")], {"route": "chat"}, "fu_question")

e = {"IHATECRYPTO_ROUTE_CANVAS": MOVE, "IHATECRYPTO_ROUTE_BALANCES": BAL,
     "IHATECRYPTO_ROUTE_RECENT": "user: верни 100 с бейза на солану|ihatecrypto: Move 100 USDC from Base to Solana. Confirm on the canvas."}
add(e, [("ru", "давай на 150"), ("en", "make it 150"), ("es", "que sean 150")], cmd(r"move 150 usdc from base to solana"), "fu_move_resize")
add(e, [("ru", "а эти 100 потом положи в камино"), ("en", "then put those 100 into kamino"), ("es", "y luego mete esos 100 en Kamino")],
    cmd(r"move 100 usdc from base to solana then deposit (?:100|99\.\d+) usdc (?:to|into) kamino"), "fu_move_then")
add(e, [("ru", "сколько это будет стоить?"), ("en", "how much will that cost?"), ("es", "¿cuánto cuesta?")], {"route": "chat"}, "fu_move_cost")
add(e, [("ru", "подтверждаю"), ("en", "confirmed, do it"), ("es", "confirmo")], {"route": "confirm"}, "fu_move_confirm")

e = {"IHATECRYPTO_ROUTE_CANVAS": KAMINO, "IHATECRYPTO_ROUTE_BALANCES": BAL,
     "IHATECRYPTO_ROUTE_RECENT": "user: закинь 20 в камино|ihatecrypto: Deposit 20 USDC into Kamino at 5.81%. Confirm on the canvas."}
add(e, [("ru", "давай на 30"), ("en", "make it 30"), ("es", "mejor 30")], cmd(r"deposit 30 usdc (?:to|into) kamino"), "fu_kamino_resize")
add(e, [("ru", "а лучше в джупитер"), ("en", "actually put it in jupiter lend instead"), ("es", "mejor en Jupiter Lend")], cmd(r"lend 20 usdc"), "fu_kamino_swap")

e = {"IHATECRYPTO_ROUTE_PLAN": PLAN, "IHATECRYPTO_ROUTE_BALANCES": BAL,
     "IHATECRYPTO_ROUTE_RECENT": "user: лонг эфира на 10 баксов х3|ihatecrypto: Plan updated: market ETH, long, leverage 3×, money in the trade 10 USDC, the rest by the risk rules."}
def plan(**kw): return {"route": "command", "intent": kw}
add(e, [("ru", "то же самое для битка"), ("en", "same for BTC"), ("es", "lo mismo para BTC")], plan(asset="BTC", side="long", amountUSDC=10, leverage=3), "fu_plan_same")
add(e, [("ru", "плечо 5"), ("en", "leverage 5x"), ("es", "apalancamiento 5")], plan(asset="ETH", leverage=5, amountUSDC=10), "fu_plan_lev")
add(e, [("ru", "увеличь до 20 USDC"), ("en", "bump it to 20 USDC"), ("es", "súbelo a 20 USDC")], plan(asset="ETH", amountUSDC=20, leverage=3), "fu_plan_amount")
add(e, [("ru", "риск 1 доллар"), ("en", "risk $1"), ("es", "riesgo de 1 dólar")], plan(asset="ETH", riskUSD=1), "fu_plan_risk")
add(e, [("ru", "сделай шорт"), ("en", "flip it to a short"), ("es", "hazlo short")], plan(asset="ETH", side="short"), "fu_plan_flip")
add(e, [("ru", "стоп 2%, тейк 3R"), ("en", "stop 2% take 3R"), ("es", "stop 2% take 3R")], plan(asset="ETH", stopPct=2, takeR=3), "fu_plan_stop")

e = {"IHATECRYPTO_ROUTE_BALANCES": BAL,
     "IHATECRYPTO_ROUTE_RECENT": "user: что с эфиром?|ihatecrypto: ETH at 2,712, −1.8% today, funding neutral. Want a price alert at 2,600, the day's low?"}
add(e, [("ru", "да"), ("ru", "давай"), ("en", "yes please"), ("es", "sí")], cmd(r"alert me when eth is (?:below|at) \$?2,?600"), "fu_yes_alert")
# A note without a folder named, on a canvas of notes in a folder, goes to that folder (Apple's model made a new one, 2026-10-04).
e = {"IHATECRYPTO_ROUTE_CANVAS": "this canvas is 2 notes in folder «ideas»: «Если биткоин упадёт ниже 82 000, не покупать MOO», «Если биткоин упадет ниже 40к то не покупать МОО»",
     "IHATECRYPTO_ROUTE_RECENT": "user: добавь еще одну заметку что если биткоин упадет ниже 40к то не покупать МОО|ihatecrypto: Записал заметку в «ideas» — она на холсте."}
for lang, m, must in [("ru", "добавь заметку если биткоин будет выше 30к то покупать $MOO", "30"), ("ru", "ещё заметка: проверить ставки в пятницу", "пятниц"),
                      ("ru", "запиши: продать половину MOO если вырастет х2", "moo"), ("en", "add a note: check the rates on friday", "friday"),
                      ("en", "another note - sell half of MOO if it doubles", "moo"), ("es", "añade una nota: revisar las tasas el viernes", "viernes"),
                      ("ru", "добавь заметку: если эфир выше 3000, алерт и лонг", "3,?000"), ("en", "note: if BTC breaks 100k, buy SOL for 20 bucks", "100")]:
    add(e, [(lang, m)], {"route": "command", "cmd": [rf"^write to folder «?ideas»?: .*{must}.*$"]}, "fu_note_same_folder")

# With a position open: stops, takes, closing a share, cancelling the limit (one position: no ticker needed).
e = {"IHATECRYPTO_ROUTE_POSITIONS": "long ETH"}
for lang, m, r in [("ru", "стоп в безубыток", "move stop to breakeven(?: eth)?"), ("en", "move my stop to breakeven", "move stop to breakeven(?: eth)?"),
                   ("ru", "закрой половину эфира", "close half(?: (?:of )?eth)?|close 50%(?: (?:of )?eth)?"), ("en", "close half of my ETH position", "close half(?: (?:of )?eth)?|close 50%(?: (?:of )?eth)?"),
                   ("es", "cierra la mitad de ETH", "close half(?: (?:of )?eth)?|close 50%(?: (?:of )?eth)?"), ("ru", "поставь стоп на 2600", r"stop at \$?2,?600(?: eth)?"),
                   ("en", "set my stop at 2600", r"stop at \$?2,?600(?: eth)?"), ("es", "pon el stop en 2600", r"stop at \$?2,?600(?: eth)?"),
                   ("ru", "тейк на 3100", r"take at \$?3,?100(?: eth)?"), ("en", "take profit at 3100", r"take at \$?3,?100(?: eth)?"),
                   ("ru", "трейли стоп 2%", "trail 2%(?: eth)?"), ("en", "trail the stop 2%", "trail 2%(?: eth)?"), ("ru", "закрой четверть", "close 25%(?: (?:of )?eth)?"),
                   ("en", "close a quarter", "close 25%(?: (?:of )?eth)?"), ("ru", "закрой всё", "close(?: eth)?"), ("en", "close it", "close(?: eth)?"),
                   ("es", "cierra todo", "close(?: eth)?"), ("ru", "отмени лимитку", "cancel orders(?: eth)?"), ("en", "cancel the limit order", "cancel orders(?: eth)?"),
                   ("ru", "закрой 30% позиции", "close 30%(?: (?:of )?eth)?")]:
    add(e, [(lang, m)], cmd(r), "position_open")
for i, c in enumerate(cases): c["id"] = 100000 + i
for c in cases: print(json.dumps(c, ensure_ascii=False))
