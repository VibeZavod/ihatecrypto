#!/usr/bin/env python3
"""Phrases people type, in ru/en/es with slang, number words and typos, each with what the router must answer.

Output: JSONL {id, lang, kind, message, expect: {route, cmd: [regex…] (any matches), intent: {field: value}}}.
The command is compared lowercased, spaces collapsed, a trailing full stop dropped."""
import json
import random
import sys

rnd = random.Random(int(sys.argv[2]) if len(sys.argv) > 2 else 4)
N = int(sys.argv[1]) if len(sys.argv) > 1 else 2000

WORDS = {
    "ru": {1: "один", 2: "два", 3: "три", 5: "пять", 10: "десять", 20: "двадцать", 50: "пятьдесят", 100: "сто"},
    "en": {1: "one", 2: "two", 3: "three", 5: "five", 10: "ten", 20: "twenty", 50: "fifty", 100: "a hundred"},
    "es": {1: "un", 2: "dos", 3: "tres", 5: "cinco", 10: "diez", 20: "veinte", 50: "cincuenta", 100: "cien"},
}


def money(lang, v):
    """«5 баксов», «$5», «five bucks», «5 USDC»…: the way people write a dollar amount."""
    w = WORDS[lang].get(v) if isinstance(v, int) else None
    num = str(v) if lang == "en" or not isinstance(v, float) else str(v).replace(".", ",") if lang == "ru" and rnd.random() < 0.5 else str(v)
    forms = {
        "ru": [f"{num} баксов", f"{num}$", f"${num}", f"{num} usdc", f"{num} юсдс", f"{num} долларов", f"{num} бачей"] + ([f"{w} баксов", f"{w} долларов"] if w else []),
        "en": [f"${num}", f"{num} bucks", f"{num} USDC", f"{num} dollars", f"{num} usdc"] + ([f"{w} bucks", f"{w} dollars"] if w else []),
        "es": [f"{num} dólares", f"{num} USDC", f"${num}", f"{num} pavos", f"{num} usdc"] + ([f"{w} dólares"] if w else []),
    }[lang]
    return rnd.choice(forms)


def num_re(v):
    s = f"{v:g}" if isinstance(v, float) else str(v)
    return s.replace(".", r"\.") + r"(?:\.0+)?"


NETS = {  # key: (en form, ru words, es words)
    "base": ("base", ["бейз", "бейс", "base", "базе"], ["Base", "base"]),
    "arbitrum": ("arbitrum", ["арбитрум", "arbitrum", "арб"], ["Arbitrum", "arbitrum"]),
    "polygon": ("polygon", ["полигон", "polygon"], ["Polygon"]),
    "ethereum": ("ethereum", ["эфир", "эфириум", "мейннет", "ethereum"], ["Ethereum", "mainnet"]),
    "robinhood": ("robinhood", ["робингуд", "робинхуд", "robinhood"], ["Robinhood"]),
    "tempo": ("tempo", ["темпо", "tempo"], ["Tempo"]),
}
RU_NET_PREP = {"base": "на бейз", "arbitrum": "на арбитрум", "polygon": "в полигон", "ethereum": "на эфир", "robinhood": "на робингуд", "tempo": "в темпо"}
RU_NET_FROM = {"base": "с бейза", "arbitrum": "с арбитрума", "polygon": "с полигона", "ethereum": "с эфира", "robinhood": "с робингуда", "tempo": "с темпо"}


def typo(s):
    """One slip in a word (not a number, not an address): a letter dropped, doubled or swapped."""
    words = s.split(" ")
    idx = [i for i, w in enumerate(words) if len(w) > 4 and w.isalpha() and not w.isupper()]
    if not idx:
        return s
    i = rnd.choice(idx)
    w = list(words[i])
    k = rnd.randrange(1, len(w) - 1)
    op = rnd.choice(["drop", "dup", "swap"])
    if op == "drop":
        del w[k]
    elif op == "dup":
        w.insert(k, w[k])
    else:
        w[k], w[k + 1] = w[k + 1], w[k]
    words[i] = "".join(w)
    return " ".join(words)


AMTS = [1, 2, 3, 5, 10, 20, 50, 100, 1.5, 2.5, 7, 15, 12, 4, 0.5]
SMALL = [0.01, 0.02, 0.05, 0.1, 0.5]
ASSETS = [  # word per language, expected Hyperliquid coin
    ({"ru": ["эфир", "эфира", "ETH", "эфириум"], "en": ["ETH", "ether", "ethereum"], "es": ["ETH", "ether"]}, "ETH"),
    ({"ru": ["битка", "биток", "BTC", "биткоин"], "en": ["BTC", "bitcoin"], "es": ["BTC", "bitcoin"]}, "BTC"),
    ({"ru": ["солану", "SOL", "сол"], "en": ["SOL", "solana"], "es": ["SOL", "solana"]}, "SOL"),
    ({"ru": ["нефть", "нефти"], "en": ["oil", "crude"], "es": ["petróleo", "oil"]}, "xyz:CL"),
    ({"ru": ["золото", "золота"], "en": ["gold"], "es": ["oro", "gold"]}, "xyz:GOLD"),
    ({"ru": ["теслу", "TSLA"], "en": ["TSLA", "Tesla"], "es": ["Tesla", "TSLA"]}, "xyz:TSLA"),
    ({"ru": ["HYPE", "хайп"], "en": ["HYPE"], "es": ["HYPE"]}, "HYPE"),
    ({"ru": ["пепе", "PEPE"], "en": ["PEPE"], "es": ["PEPE"]}, "kPEPE"),
    ({"ru": ["брент"], "en": ["brent", "brent oil"], "es": ["brent"]}, "xyz:BRENTOIL"),
    ({"ru": ["NVDA", "нвидию"], "en": ["NVDA", "Nvidia"], "es": ["NVDA", "Nvidia"]}, "xyz:NVDA"),
]
CHART_EN = {"ETH": "eth", "BTC": "btc", "SOL": "sol", "xyz:CL": "(?:oil|wti|cl|crude)", "xyz:GOLD": "gold", "xyz:TSLA": "(?:tsla|tesla)",
            "HYPE": "hype", "kPEPE": "(?:kpepe|pepe)", "xyz:BRENTOIL": "(?:brent|brentoil|brent oil)", "xyz:NVDA": "(?:nvda|nvidia)"}

KINDS = []


def kind(f):
    KINDS.append(f)
    return f


def cmd(*res):
    return {"route": "command", "cmd": ["^" + r + "$" for r in res]}


@kind
def kamino_in(lang):
    v = rnd.choice(AMTS); m = money(lang, v)
    t = {"ru": [f"закинь {m} в камино", f"положи {m} в kamino", f"задепозить {m} в камино", f"хочу положить {m} в камино пусть лежат"],
         "en": [f"put {m} into Kamino", f"deposit {m} in kamino", f"throw {m} in kamino pls"],
         "es": [f"deposita {m} en Kamino", f"mete {m} en kamino", f"pon {m} en Kamino"]}[lang]
    return rnd.choice(t), cmd(f"deposit {num_re(v)} usdc (?:to|into) kamino")


@kind
def kamino_out(lang):
    v = rnd.choice(AMTS); m = money(lang, v)
    t = {"ru": [f"выведи {m} из камино", f"сними {m} с kamino", f"забери {m} из камино"],
         "en": [f"withdraw {m} from Kamino", f"take {m} out of kamino"],
         "es": [f"retira {m} de Kamino", f"saca {m} de kamino"]}[lang]
    return rnd.choice(t), cmd(f"withdraw {num_re(v)} usdc from kamino")


@kind
def lend(lang):
    v = rnd.choice(AMTS); m = money(lang, v)
    t = {"ru": [f"положи {m} в джупитер", f"закинь {m} в jupiter lend", f"депозит {m} в юпитер волт"],
         "en": [f"lend {m} on Jupiter", f"put {m} in the jupiter vault", f"deposit {m} to Jupiter Lend"],
         "es": [f"presta {m} en Jupiter Lend", f"deposita {m} en el vault de Jupiter"]}[lang]
    return rnd.choice(t), cmd(f"lend {num_re(v)} usdc")


@kind
def hl_out(lang):
    v = rnd.choice(AMTS); m = money(lang, v)
    t = {"ru": [f"выведи {m} с гипера", f"верни {m} с хайпера на солану", f"сними {m} с hyperliquid"],
         "en": [f"withdraw {m} from Hyperliquid", f"pull {m} off HL back to solana"],
         "es": [f"saca {m} de Hyperliquid", f"retira {m} de Hyperliquid a Solana"]}[lang]
    return rnd.choice(t), cmd(f"withdraw {num_re(v)} usdc to solana")


@kind
def hlp_in(lang):
    v = rnd.choice([5, 10, 20, 50]); m = money(lang, v)
    t = {"ru": [f"положи {m} в HLP", f"закинь {m} в хлп"], "en": [f"deposit {m} into HLP", f"put {m} in the HLP vault"],
         "es": [f"deposita {m} en HLP"]}[lang]
    return rnd.choice(t), cmd(f"deposit {num_re(v)} usdc (?:to|into) hlp")


@kind
def aave_in(lang):
    v = rnd.choice(AMTS); m = money(lang, v); net = rnd.choice(["base", "arbitrum", "polygon", "ethereum"])
    en, ru, es = NETS[net]
    t = {"ru": [f"закинь {m} в aave на {rnd.choice(ru)}", f"положи {m} в ааве {RU_NET_PREP[net]}"],
         "en": [f"lend {m} on Aave on {en}", f"put {m} into aave on {en.capitalize()}"],
         "es": [f"presta {m} en Aave en {rnd.choice(es)}"]}[lang]
    opt = "(?: on base)?" if net == "base" else f" on {net}"
    return rnd.choice(t), cmd(f"lend {num_re(v)} usdc on aave{opt}")


@kind
def morpho_in(lang):
    v = rnd.choice(AMTS); m = money(lang, v); net = rnd.choice(["base", "arbitrum", "ethereum"])
    en, ru, es = NETS[net]
    t = {"ru": [f"положи {m} в морфо {RU_NET_PREP[net]}", f"закинь {m} в morpho на {rnd.choice(ru)}"],
         "en": [f"deposit {m} into Morpho on {en}", f"put {m} in morpho on {en}"],
         "es": [f"deposita {m} en Morpho en {rnd.choice(es)}"]}[lang]
    opt = "(?: on base)?" if net == "base" else f" on {net}"
    return rnd.choice(t), cmd(f"deposit {num_re(v)} usdc (?:into|to) morpho{opt}")


@kind
def evm_to_sol(lang):
    v = rnd.choice(AMTS); m = money(lang, v); net = rnd.choice(["base", "arbitrum", "polygon", "ethereum", "tempo"])
    en, ru, es = NETS[net]
    t = {"ru": [f"верни {m} {RU_NET_FROM[net]} на солану", f"переведи {m} {RU_NET_FROM[net]} в солану"],
         "en": [f"move {m} from {en} to Solana", f"bring {m} back from {en} to solana"],
         "es": [f"mueve {m} de {rnd.choice(es)} a Solana"]}[lang]
    return rnd.choice(t), cmd(f"move {num_re(v)} usdc from {net} to solana")


@kind
def sol_to_evm(lang):
    v = rnd.choice(AMTS); m = money(lang, v); net = rnd.choice(["base", "arbitrum", "polygon", "ethereum", "robinhood", "tempo"])
    en, ru, es = NETS[net]
    t = {"ru": [f"переведи {m} из соланы {RU_NET_PREP[net]}", f"закинь {m} с соланы {RU_NET_PREP[net]}"],
         "en": [f"move {m} from Solana to {en}", f"send {m} from solana over to {en}"],
         "es": [f"mueve {m} de Solana a {rnd.choice(es)}"]}[lang]
    return rnd.choice(t), cmd(f"move {num_re(v)} usdc from solana to {net}")


@kind
def evm_to_evm(lang):
    v = rnd.choice(AMTS); m = money(lang, v)
    a, b = rnd.sample(["base", "arbitrum", "polygon", "ethereum", "robinhood"], 2)
    t = {"ru": [f"перекинь {m} {RU_NET_FROM[a]} {RU_NET_PREP[b]}"],
         "en": [f"move {m} from {NETS[a][0]} to {NETS[b][0]}", f"bridge {m} {NETS[a][0]} -> {NETS[b][0]}"],
         "es": [f"pasa {m} de {NETS[a][2][0]} a {NETS[b][2][0]}"]}[lang]
    return rnd.choice(t), cmd(f"move {num_re(v)} usdc from {a} to {b}")


@kind
def evm_to_hl(lang):
    v = rnd.choice(AMTS); m = money(lang, v); net = rnd.choice(["base", "arbitrum"])
    t = {"ru": [f"закинь {m} {RU_NET_FROM[net]} на гипер", f"переведи {m} {RU_NET_FROM[net]} на хайперликвид"],
         "en": [f"move {m} from {net} to Hyperliquid"], "es": [f"mueve {m} de {net} a Hyperliquid"]}[lang]
    return rnd.choice(t), cmd(f"move {num_re(v)} usdc from {net} to hyperliquid")


@kind
def send_name(lang):
    v = rnd.choice(AMTS); m = money(lang, v); name = rnd.choice(["Mom", "Bybit"])
    who = {"Mom": {"ru": ["маме", "на Mom"], "en": ["Mom", "mom"], "es": ["a Mom", "a mamá (Mom)"]}, "Bybit": {"ru": ["на Bybit", "на байбит"], "en": ["Bybit", "to bybit"], "es": ["a Bybit"]}}[name][lang]
    w = rnd.choice(who)
    t = {"ru": [f"переведи {w} {m}", f"отправь {m} {w}", f"скинь {w} {m}"],
         "en": [f"send {m} to {w.replace('to ', '')}", f"send {w.replace('to ', '')} {m}"],
         "es": [f"envía {m} {w}", f"manda {m} {w}"]}[lang]
    return rnd.choice(t), cmd(f"send {num_re(v)} usdc to {name.lower()}")


@kind
def send_name_net(lang):
    v = rnd.choice(AMTS); m = money(lang, v); net = rnd.choice(["arbitrum", "ethereum", "base", "polygon"])
    en, ru, es = NETS[net]
    t = {"ru": [f"отправь {m} на Bybit в сети {rnd.choice(ru)}", f"переведи {m} на bybit по {rnd.choice(ru)} сети"],
         "en": [f"send {m} to Bybit on {en}", f"send {m} to bybit via {en}"],
         "es": [f"envía {m} a Bybit en {rnd.choice(es)}"]}[lang]
    return rnd.choice(t), cmd(f"send {num_re(v)} usdc to bybit on {net}", f"send {num_re(v)} usdc on {net} to bybit")


@kind
def send_sol(lang):
    v = rnd.choice(SMALL)
    t = {"ru": [f"отправь {v} сол на Bybit", f"скинь {v} SOL маме"], "en": [f"send {v} SOL to Bybit", f"send mom {v} sol"],
         "es": [f"envía {v} SOL a Bybit"]}[lang]
    p = rnd.choice(t)
    name = "mom" if ("мам" in p or "mom" in p) else "bybit"
    return p, cmd(f"send {num_re(v)} sol to {name}")


@kind
def buy_spot(lang):
    v = rnd.choice(AMTS); m = money(lang, v)
    coin, words = rnd.choice([("sol", {"ru": ["сол", "солану", "SOL"], "en": ["SOL", "some sol"], "es": ["SOL"]}),
                              ("btc", {"ru": ["битка", "BTC", "биток"], "en": ["BTC", "bitcoin"], "es": ["BTC", "bitcoin"]}),
                              ("jup", {"ru": ["JUP", "джуп"], "en": ["JUP"], "es": ["JUP"]})])
    a = rnd.choice(words[lang])
    t = {"ru": [f"купи {a} на {m}", f"закупись {a} на {m}"], "en": [f"buy {m} of {a}", f"buy {a} for {m}", f"grab {m} worth of {a}"],
         "es": [f"compra {a} por {m}", f"compra {m} de {a}"]}[lang]
    return rnd.choice(t), cmd(f"buy {coin} for {num_re(v)} usdc", f"buy {coin} on solana for {num_re(v)} usdc")


@kind
def sell_spot(lang):
    v = rnd.choice(SMALL)
    t = {"ru": [f"продай {v} сол", f"слей {v} SOL"], "en": [f"sell {v} SOL", f"dump {v} sol"], "es": [f"vende {v} SOL"]}[lang]
    return rnd.choice(t), cmd(f"sell {num_re(v)} sol")


@kind
def jup_token(lang):
    v = rnd.choice(AMTS); m = money(lang, v); tok = rnd.choice(["BONK", "WIF", "JTO", "PYTH", "POPCAT", "RAY"])
    t = {"ru": [f"купи {tok} на {m}", f"возьми {tok} на солане на {m}"], "en": [f"buy {tok} for {m}", f"get me {m} of {tok} on solana"],
         "es": [f"compra {tok} por {m}"]}[lang]
    return rnd.choice(t), cmd(f"buy {tok.lower()} on solana for {num_re(v)} usdc")


@kind
def evm_token(lang):
    v = rnd.choice(AMTS); m = money(lang, v)
    net, tok = rnd.choice([("base", "AERO"), ("base", "DEGEN"), ("arbitrum", "GMX"), ("arbitrum", "PENDLE"), ("ethereum", "LDO"), ("polygon", "WPOL")])
    t = {"ru": [f"купи {tok} {RU_NET_PREP[net].replace('в полигон', 'на полигоне').replace('на бейз', 'на бейзе').replace('на арбитрум', 'на арбитруме').replace('на эфир', 'на эфире')} на {m}"],
         "en": [f"buy {tok} on {net} for {m}"], "es": [f"compra {tok} en {net} por {m}"]}[lang]
    return rnd.choice(t), cmd(f"buy {tok.lower()} on {net} for {num_re(v)} usdc(?: from \\w+)?")


@kind
def stock(lang):
    v = rnd.choice(AMTS); m = money(lang, v)
    sym, w = rnd.choice([("tsla", {"ru": "акции теслы", "en": "Tesla stock", "es": "acciones de Tesla"}),
                         ("nvda", {"ru": "акции нвидии", "en": "Nvidia shares", "es": "acciones de Nvidia"}),
                         ("spcx", {"ru": "акции спейсикс", "en": "SpaceX stock", "es": "acciones de SpaceX"})])
    names = {"tsla": "(?:tsla|tesla)", "nvda": "(?:nvda|nvidia)", "spcx": "(?:spcx|spacex)"}[sym]
    t = {"ru": [f"купи {w['ru']} на {m}"], "en": [f"buy {m} of {w['en']}"], "es": [f"compra {w['es']} por {m}"]}[lang]
    return rnd.choice(t), cmd(f"buy {names} stock for {num_re(v)} usdc")


@kind
def plan_long(lang):
    words, coin = rnd.choice(ASSETS)
    a = rnd.choice(words[lang]); v = rnd.choice([5, 10, 20, 3]); lev = rnd.choice([2, 3, 5])
    m = money(lang, v)
    t = {"ru": [f"лонг {a} на {m} плечо {lev}", f"открой лонг по {a} на {m} х{lev}", f"зайди в лонг {a} {m} с плечом {lev}"],
         "en": [f"long {a} with {m} at {lev}x", f"open a {lev}x long on {a} for {m}"],
         "es": [f"abre un long de {a} con {m} a {lev}x", f"long en {a} por {m} apalancamiento {lev}"]}[lang]
    return rnd.choice(t), {"route": "command", "intent": {"asset": coin, "side": "long", "amountUSDC": v, "leverage": lev}}


@kind
def plan_short_risk(lang):
    words, coin = rnd.choice(ASSETS)
    a = rnd.choice(words[lang]); r = rnd.choice([1, 2, 0.5]); s = rnd.choice([2, 3, 1.5])
    rs = str(r).replace(".", ",") if lang == "ru" and isinstance(r, float) else str(r)
    t = {"ru": [f"шорт {a} риск {rs}$ стоп {s}%", f"зашорть {a}, рискую {rs} бакса, стоп {s}%"],
         "en": [f"short {a} risk ${r} stop {s}%", f"short {a}, risking ${r}, {s}% stop"],
         "es": [f"short en {a} con riesgo de {r} dólares y stop del {s}%"]}[lang]
    return rnd.choice(t), {"route": "command", "intent": {"asset": coin, "side": "short", "riskUSD": r, "stopPct": s}}


@kind
def plan_book(lang):
    words, coin = rnd.choice(ASSETS); a = rnd.choice(words[lang])
    side = rnd.choice(["long", "short"])
    t = {"ru": [f"{'лонг' if side == 'long' else 'шорт'} {a} по правилам", f"{'лонгани' if side == 'long' else 'зашорть'} {a} как учат"],
         "en": [f"{side} {a} by the book", f"{side} {a}, do it properly"],
         "es": [f"{side} de {a} según las reglas"]}[lang]
    return rnd.choice(t), {"route": "command", "intent": {"asset": coin, "side": side, "autoRules": True}}


@kind
def chart(lang):
    words, coin = rnd.choice(ASSETS); a = rnd.choice(words[lang]); week = rnd.random() < 0.5
    t = {"ru": [f"покажи график {a}" + (" за неделю" if week else ""), f"чарт {a}" + (" за неделю" if week else "")],
         "en": [f"show me the {a} chart" + (" for the week" if week else ""), f"chart {a}" + (" week" if week else "")],
         "es": [f"muéstrame el gráfico de {a}" + (" de la semana" if week else "")]}[lang]
    rng = " week" if week else "(?: day)?"
    return rnd.choice(t), {"route": "any", "cmd_or_show": [f"^chart {CHART_EN[coin]}{rng}$"]}


@kind
def alert(lang):
    words, coin = rnd.choice(ASSETS[:5]); a = rnd.choice(words[lang])
    p = rnd.choice({"ETH": [2680, 3000, 4000, 2450], "BTC": [95000, 120000, 110500], "SOL": [150, 200, 175], "xyz:CL": [70, 85, 62], "xyz:GOLD": [3800, 4200, 4500]}[coin])
    up = rnd.random() < 0.5
    t = {"ru": [f"скажи когда {a} будет {'выше' if up else 'ниже'} {p}", f"алерт если {a} {'поднимется выше' if up else 'упадет ниже'} {p}"],
         "en": [f"tell me when {a} goes {'above' if up else 'below'} {p}", f"ping me if {a} {'breaks' if up else 'drops under'} {p}"],
         "es": [f"avísame cuando {a} {'suba de' if up else 'baje de'} {p}"]}[lang]
    pr = f"{p:,}".replace(",", ",?")
    side = "(?:above|at)" if up else "(?:below|at)"  # «breaks 3000»: the app picks the side from the price
    return rnd.choice(t), cmd(f"alert me when {CHART_EN[coin]} is {side} \\$?{pr}")


@kind
def pnl(lang):
    per = rnd.choice(["week", "today", "month", ""])
    ru = {"week": " за неделю", "today": " за сегодня", "month": " за месяц", "": ""}[per]
    en = {"week": " this week", "today": " today", "month": " this month", "": ""}[per]
    es = {"week": " esta semana", "today": " hoy", "month": " este mes", "": ""}[per]
    t = {"ru": [f"какой у меня пнл{ru}", f"сколько я заработал{ru}?"], "en": [f"what's my pnl{en}", f"how much did I make{en}?"],
         "es": [f"cuál es mi PnL{es}", f"cuánto gané{es}?"]}[lang]
    p = {"week": "week", "today": "today", "month": "month", "": "(?:all)?"}[per]
    return rnd.choice(t), cmd(f"profit and loss ?{p}")


@kind
def spread(lang):
    v = rnd.choice([50, 100, 20, 10, 1000]); m = money(lang, v); wo = rnd.random() < 0.4
    t = {"ru": [f"разложи {m} по лучшим ставкам" + (" без камино" if wo else ""), f"раскидай {m} по лучшим волтам" + (", только не в камино" if wo else "")],
         "en": [f"spread {m} across the best rates" + (" but skip kamino" if wo else ""), f"put {m} in the best yields" + (" without kamino" if wo else "")],
         "es": [f"reparte {m} entre las mejores tasas" + (" sin Kamino" if wo else "")]}[lang]
    return rnd.choice(t), cmd(f"spread {num_re(v)} usdc(?: from \\w+)? across the best rates(?: max \\d+% per protocol)?" + (" without kamino" if wo else ""))


@kind
def rebalance(lang):
    t = {"ru": ["переложи депозиты в лучшие ставки", "перебалансируй мои вклады"], "en": ["rebalance my deposits", "move my deposits to better rates"],
         "es": ["rebalancea mis depósitos"]}[lang]
    return rnd.choice(t), cmd("rebalance usdc(?: max \\d+% per protocol)?")


@kind
def stake(lang):
    v = rnd.choice(SMALL)
    t = {"ru": [f"застейкай {v} сол", f"стейкни {v} SOL"], "en": [f"stake {v} SOL"], "es": [f"haz staking de {v} SOL"]}[lang]
    return rnd.choice(t), cmd(f"stake {num_re(v)} sol")


@kind
def gas(lang):
    net = rnd.choice(["base", "arbitrum", "robinhood", "polygon"])
    t = {"ru": [f"докинь газа {RU_NET_PREP[net]}", f"добавь газ {RU_NET_PREP[net]}"], "en": [f"add some gas on {net}", f"top up gas on {net}"],
         "es": [f"añade gas en {net}"]}[lang]
    return rnd.choice(t), cmd(f"add gas on {net}(?: for 1 usdc)?")


@kind
def later(lang):
    t = {"ru": ["через неделю переложи депозиты в лучшие ставки"], "en": ["in a week rebalance my deposits"], "es": ["dentro de una semana rebalancea mis depósitos"]}[lang]
    return rnd.choice(t), cmd("in (?:1|one) week: rebalance usdc(?: max \\d+% per protocol)?", "in 7 days: rebalance usdc(?: max \\d+% per protocol)?")


@kind
def recurring(lang):
    v = rnd.choice([5, 10, 20]); m = money(lang, v)
    t = {"ru": [f"покупай сол на {m} каждую неделю", f"каждую неделю покупай SOL на {m}"], "en": [f"buy {m} of SOL every week"],
         "es": [f"compra SOL por {m} cada semana"]}[lang]
    return rnd.choice(t), cmd(f"buy sol for {num_re(v)} usdc every week", f"every week: buy sol for {num_re(v)} usdc", f"every (?:monday|\\w+day)(?: at \\d\\d:\\d\\d)?: buy sol for {num_re(v)} usdc")


@kind
def monthly_send(lang):
    v = rnd.choice([10, 20, 50]); m = money(lang, v)
    t = {"ru": [f"каждое 1-е число переводи маме {m}"], "en": [f"send mom {m} on the 1st of every month"], "es": [f"envía {m} a Mom el día 1 de cada mes"]}[lang]
    return rnd.choice(t), cmd(f"every month on the 1st(?: at \\d\\d:\\d\\d)?: send {num_re(v)} usdc to mom")


@kind
def alert_steps(lang):
    p = rnd.choice([2680, 2500, 3000])
    t = {"ru": [f"когда эфир упадет ниже {p} открой лонг х3", f"если ETH опустится ниже {p}, лонгани с плечом 3"],
         "en": [f"when ETH drops below {p} open a 3x long"], "es": [f"cuando ETH baje de {p} abre un long a 3x"]}[lang]
    pr = f"{p:,}".replace(",", ",?")
    return rnd.choice(t), cmd(f"when eth is below {pr}: long eth.*leverage 3x.*")


@kind
def chain(lang):
    v = rnd.choice([5, 10, 3]); m = money(lang, v)
    t = {"ru": [f"выведи {m} с гипера и положи в камино", f"сними {m} с хайпера, а потом закинь в kamino"],
         "en": [f"withdraw {m} from hyperliquid and put it in kamino"], "es": [f"saca {m} de Hyperliquid y ponlos en Kamino"]}[lang]
    return rnd.choice(t), cmd(f"withdraw {num_re(v)} usdc to solana then deposit {num_re(v)} usdc (?:to|into) kamino")


@kind
def claim(lang):
    t = {"ru": ["забери награды", "заклейми ревард"], "en": ["claim my rewards"], "es": ["reclama mis recompensas"]}[lang]
    return rnd.choice(t), cmd("claim rewards")


@kind
def breakeven(lang):
    t = {"ru": ["стоп в безубыток", "перенеси стоп в бу"], "en": ["move my stop to breakeven"], "es": ["mueve el stop a breakeven"]}[lang]
    return rnd.choice(t), {"route": ["command", "clarify", "chat"]}  # no position open here: «nothing to move» is right too


@kind
def close_half(lang):
    t = {"ru": ["закрой половину эфира", "закрой пол позиции по ETH"], "en": ["close half of my ETH position"], "es": ["cierra la mitad de ETH"]}[lang]
    return rnd.choice(t), {"route": ["command", "clarify", "chat"]}  # no position open here (followups.py opens one)


@kind
def fav(lang):
    t = {"ru": ["добавь Bybit в избранное"], "en": ["add Bybit to favorites"], "es": ["añade Bybit a favoritos"]}[lang]
    return rnd.choice(t), cmd("add bybit to favorites")


@kind
def new_canvas(lang):
    t = {"ru": ["создай новый холст", "новый канвас"], "en": ["new canvas please", "open a fresh canvas"], "es": ["crea un lienzo nuevo"]}[lang]
    return rnd.choice(t), cmd("new canvas")


@kind
def folder_save(lang):
    t = {"ru": ["сохрани этот холст в папку Ресерч"], "en": ["save this canvas to my Research folder"], "es": ["guarda este lienzo en la carpeta Research"]}[lang]
    f = "ресерч" if lang == "ru" else "research"
    return rnd.choice(t), cmd(f"save this canvas to folder {f}")


@kind
def folder_note(lang):
    t = {"ru": ["запиши в папку Идеи: купить эфир на откате, алерт на 2500"], "en": ["write to folder Ideas: buy ETH on a dip, alert at 2500"],
         "es": ["escribe en la carpeta Ideas: comprar ETH en una caída, alerta en 2500"]}[lang]
    p = rnd.choice(t)
    folder, text = p.split(": ", 1)[0].split()[-1].lower(), p.split(": ", 1)[1].lower()
    return p, {"route": "command", "cmd": [f"^write to folder {folder}: .*2,?500.*$"]}


@kind
def near_buy(lang):
    v = rnd.choice([2, 5, 10]); m = money(lang, v)
    t = {"ru": [f"купи неар на {m}"], "en": [f"buy {m} of NEAR"], "es": [f"compra NEAR por {m}"]}[lang]
    return rnd.choice(t), cmd(f"buy near for {num_re(v)} usdc")


@kind
def unstake(lang):
    v = rnd.choice(SMALL)
    t = {"ru": [f"анстейкни {v} jitosol"], "en": [f"unstake {v} JitoSOL"], "es": [f"retira {v} JitoSOL del staking"]}[lang]
    return rnd.choice(t), cmd(f"unstake {num_re(v)} jitosol")


@kind
def stop_dca(lang):
    t = {"ru": ["останови регулярные покупки"], "en": ["stop my recurring buys"], "es": ["detén las compras recurrentes"]}[lang]
    return rnd.choice(t), cmd("stop recurring buys")


@kind
def cancel_alerts(lang):
    t = {"ru": ["отмени все алерты"], "en": ["cancel all my alerts"], "es": ["cancela todas las alertas"]}[lang]
    return rnd.choice(t), cmd("cancel alerts")


@kind
def hlp_out(lang):
    t = {"ru": ["выведи всё из HLP"], "en": ["withdraw everything from HLP"], "es": ["retira todo de HLP"]}[lang]
    return rnd.choice(t), cmd("withdraw usdc from hlp")


@kind
def aave_out(lang):
    t = {"ru": ["забери всё из aave на арбитруме"], "en": ["withdraw all my USDC from Aave on Arbitrum"], "es": ["saca todo de Aave en Arbitrum"]}[lang]
    return rnd.choice(t), cmd("withdraw usdc from aave on arbitrum")


@kind
def usdg_back(lang):
    t = {"ru": ["верни usdg с робингуда на солану"], "en": ["bring my USDG from Robinhood back to Solana"], "es": ["devuelve mis USDG de Robinhood a Solana"]}[lang]
    return rnd.choice(t), cmd("move usdg from robinhood to solana")


@kind
def sweep(lang):
    t = {"ru": ["продавай награды раз в час, когда наберется $10"], "en": ["every hour sell my rewards once they're worth $10"],
         "es": ["cada hora vende mis recompensas cuando valgan 10 dólares"]}[lang]
    return rnd.choice(t), cmd("every hour: sweep rewards over \\$10(?: into usdc)?")


@kind
def two_trades(lang):
    t = {"ru": ["лонг эфира и шорт битка"], "en": ["long ETH and short BTC"], "es": ["long de ETH y short de BTC"]}[lang]
    return rnd.choice(t), {"route": "clarify"}


@kind
def unsupported(lang):
    t = {"ru": ["застейкай эфир", "купи доджа на кракене"], "en": ["stake my ETH", "buy DOGE on Kraken"], "es": ["haz staking de mi ETH"]}[lang]
    return rnd.choice(t), {"route": ["clarify", "chat"]}


@kind
def chat_q(lang):
    t = {"ru": ["что такое HLP?", "как дела?", "расскажи анекдот", "в чем разница между Aave и Morpho?"],
         "en": ["what is HLP?", "how are you?", "tell me a joke", "what's the difference between Aave and Morpho?"],
         "es": ["¿qué es HLP?", "¿cómo estás?", "cuéntame un chiste"]}[lang]
    return rnd.choice(t), {"route": "chat"}


@kind
def vague(lang):
    t = {"ru": ["переведи деньги", "купи что-нибудь"], "en": ["move some money", "buy something"], "es": ["mueve dinero"]}[lang]
    return rnd.choice(t), {"route": ["clarify", "chat"]}


def main():
    out, seen = [], set()
    langs = ["ru", "en", "es"]
    i = 0
    while len(out) < N and i < N * 40:
        lang = langs[i % 3]
        k = KINDS[(i // 3) % len(KINDS)]
        i += 1
        msg, exp = k(lang)
        if rnd.random() < 0.25:
            msg = typo(msg)
        if msg in seen:
            continue
        seen.add(msg)
        out.append({"id": len(out), "lang": lang, "kind": k.__name__, "message": msg, "expect": exp})
    for o in out:
        print(json.dumps(o, ensure_ascii=False))


main()
