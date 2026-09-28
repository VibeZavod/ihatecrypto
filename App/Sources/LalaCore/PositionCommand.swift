import Foundation

/// What the user can say about a position that is already open («стоп в безубыток», «закрой половину»).
/// Deterministic like the plan parser; only checked while a position or order exists.
public enum PositionCommand: Equatable, Sendable {
    /// Share of the position to close, 0 < f ≤ 1.
    case close(Decimal)
    case stopToBreakeven
    case stopTo(Decimal)
    case takeTo(Decimal)
    case cancelOrders
    /// Keep the stop N% behind the best price; LALA's guardian moves it, only ever tighter.
    case trail(Decimal)

    public static func parse(_ text: String) -> PositionCommand? {
        let q = text.lowercased()
        if q.contains(/отмени\w*\s+(?:лимит|ордер|заявк)|сними\w*\s+(?:лимит|ордер|заявк)|cancel\s+(?:the\s+|my\s+)?(?:limit|order)|remove\s+(?:the\s+)?(?:limit|order)/) { return .cancelOrders }
        if q.contains(/безубыт|стоп\w*\s+(?:в|на)\s+(?:ноль|бу\b|вход)|break\s*-?\s*even|stop\s+(?:to|at)\s+entry/) { return .stopToBreakeven }
        if let m = q.firstMatch(of: /(?:(?:перенес\w*|передвин\w*|подвин\w*|постав\w*)?\s*стоп\w*\s+(?:на|в)|(?:move|set|put)?\s*(?:the\s+)?stop(?:[- ]?loss)?\s+(?:to|at))\s+\$?(\d+(?:[.,]\d+)?)(?!\s*%|[\d.,])/),
           let v = Decimal(string: m.1.replacingOccurrences(of: ",", with: ".")) {
            return .stopTo(v)
        }
        if let m = q.firstMatch(of: /(?:(?:перенес\w*|передвин\w*|подвин\w*|постав\w*)?\s*тейк\w*\s+(?:на|в)|(?:move|set|put)?\s*(?:the\s+)?take(?:[- ]?profit)?\s+(?:to|at))\s+\$?(\d+(?:[.,]\d+)?)(?!\s*%|[\d.,])/),
           let v = Decimal(string: m.1.replacingOccurrences(of: ",", with: ".")) {
            return .takeTo(v)
        }
        // «trail 2%» about the open position; a new plan with a trailing stop («long ETH trailing 2%») is not this.
        if !q.contains(/лонг|шорт|\blong\b|\bshort\b/), let m = q.firstMatch(of: /(?:трейл\w*|trail\w*)[^\d]{0,15}?(\d+(?:[.,]\d+)?)\s*%/),
           let v = Decimal(string: m.1.replacingOccurrences(of: ",", with: ".")), v > 0, v < 50 {
            return .trail(v)
        }
        guard q.contains(/закр\w*|выйди|выход\w*\s+из|\bclose\b|\bexit\b/) else { return nil }
        if q.contains(/половин|50\s*%|\bhalf\b/) { return .close(Decimal(string: "0.5")!) }
        if q.contains(/треть|\bthird\b/) { return .close(Decimal(1) / 3) }
        if q.contains(/четверть|\bquarter\b/) { return .close(Decimal(string: "0.25")!) }
        if let m = q.firstMatch(of: /(\d+(?:[.,]\d+)?)\s*%/), let v = Decimal(string: m.1.replacingOccurrences(of: ",", with: ".")), v > 0, v <= 100 {
            return .close(v / 100)
        }
        return .close(1)
    }
}

/// Coins to buy and hold on Solana, by fixed verified mint: a search by ticker returns look-alikes.
public struct SpotAsset: Equatable, Sendable {
    public let symbol: String
    public let mint: String
    public let decimals: Int

    /// Checked 2026-09-25 against Jupiter's verified list (isVerified true).
    public static let all = [
        SpotAsset(symbol: "SOL", mint: "So11111111111111111111111111111111111111112", decimals: 9),
        SpotAsset(symbol: "BTC", mint: "cbbtcf3aa214zXHbiAZQwf4122FBYbraNdFqgw4iMij", decimals: 8),   // Coinbase Wrapped BTC
        SpotAsset(symbol: "ETH", mint: "7vfCXTUXx5WJV5JADk17DUJ4ksgau7utNKj4b963voxs", decimals: 8),   // Ether (Portal)
        SpotAsset(symbol: "JUP", mint: "JUPyiwrYJFskUPiHa7hkeR8VUtAeFoSYbKedZNsDvCN", decimals: 6),
        // Liquid staking: SOL that earns the staking yield and can be sold back any time.
        SpotAsset(symbol: "JitoSOL", mint: "J1toso1uCk3RLmjorhTtrVwY9HJ7X8V9yYac6Y7kGCPn", decimals: 9),
    ]
    public static let usdc = SpotAsset(symbol: "USDC", mint: "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v", decimals: 6)
    public static let jitoSOL = all[4]

    static func find(_ q: String) -> SpotAsset? {
        if q.contains(/jitosol|джито/) { return all[4] }
        if q.contains(/\bsol\b|\bсол\b|\bсолу\b|солан|solana/) { return all[0] }
        if q.contains(/\bbtc\b|биткоин|битк|bitcoin/) { return all[1] }
        if q.contains(/\beth\b|эфир|ether/) { return all[2] }
        if q.contains(/\bjup\b|юпитер|джуп|jupiter/) { return all[3] }
        return nil
    }
}

/// Moving the user's own money: back to Solana, into the USDC vault and out, spot buys and sells.
public enum WalletCommand: Equatable, Sendable {
    /// Spend `usdc` on the coin, on Solana through Jupiter; nil = ask how much.
    case buy(SpotAsset, usdc: Decimal?)
    /// Native NEAR on the NEAR chain for Solana USDC through NEAR Intents 1Click, to the wallet's own NEAR account;
    /// nil = ask how much.
    case buyNear(usdc: Decimal?)
    /// Native NEAR from the NEAR account for USDC on the Solana address, through 1Click; nil = all it can give.
    case sellNear(amount: Decimal?)
    /// Sell this much of the coin for USDC; nil = all of it (SOL keeps a fee reserve).
    case sell(SpotAsset, amount: Decimal?)
    /// Regular purchases (DCA): `usdc` of the coin every `days` days.
    case schedule(SpotAsset, usdc: Decimal, days: Int)
    case stopSchedules
    /// nil = everything withdrawable.
    case withdrawToSolana(Decimal?)
    /// Jupiter Lend: symbol («USDC», «SOL», «USDT»), amount in that asset; nil = ask how much.
    case lendDeposit(String, Decimal?)
    /// nil = the whole vault position.
    case lendWithdraw(String, Decimal?)
    /// Kamino Lend, main market.
    case kamino(deposit: Bool, symbol: String, amount: Decimal?)
    /// SOL into JitoSOL (liquid staking) and back; nil = all.
    case stake(Decimal?)
    case unstake(Decimal?)
    /// Where the asset earns most now; nil = stablecoins and SOL.
    case yields(String?)
    /// Hyperliquid's HLP vault: deposit or withdraw USDC (nil = all).
    case hlp(deposit: Bool, amount: Decimal?)
    /// «Разложи USDC по лучшим ставкам»: the asset and the most one protocol may hold, % (nil = 50).
    case allocate(String, maxShare: Decimal?)
    /// USDC into Aave v3 on Base (bridged from Solana when short) or out of it and back to Solana;
    /// nil = ask (deposit) / everything (withdraw).
    case aave(deposit: Bool, amount: Decimal?)
    /// The same with Morpho's Gauntlet USDC Prime vault on Base.
    case morpho(deposit: Bool, amount: Decimal?)
    /// USDC idle on Base back to Solana over Relay; nil = everything.
    case baseToSolana(Decimal?)
    /// The same from Arbitrum.
    case arbitrumToSolana(Decimal?)
    /// «send 5 USDC to Bybit»: to an entry of the address book, by its name. An address in the text is never a recipient.
    case sendTo(name: String, amount: Decimal)
    /// Native NEAR from the wallet's NEAR account to an address-book entry on NEAR; nil = all but the account's own
    /// storage and the fee.
    case sendNear(name: String, amount: Decimal?)
    /// Deletes the wallet's NEAR account; NEAR sends everything on it to the address-book entry `name`.
    case closeNear(name: String)
    /// Native SOL to an address-book entry on Solana; the amount is always said.
    case sendSol(name: String, amount: Decimal)
    /// «задепозить», «пополнить», «my address»: money coming in from outside — show where to send it.
    case receive
    /// A Robinhood Stock Token (SPCX, TSLA…) bought on Robinhood Chain for USDC from Solana; `symbol` as the user named
    /// it, resolved against Robinhood's registry by the app. nil amount = ask.
    case buyStock(symbol: String, usdc: Decimal?)
    /// Sell a Stock Token for USDG on Robinhood Chain; nil = all of it.
    case sellStock(symbol: String, amount: Decimal?)
    /// USDG on Robinhood Chain back to Solana as USDC; nil = everything.
    case robinhoodToSolana(Decimal?)
    /// USDC from the Solana wallet to our own address on «base», «arbitrum» or «robinhood» (USDG there); nil = ask.
    case solanaTo(String, Decimal?)

    public static func parse(_ text: String) -> WalletCommand? {
        let q = text.lowercased()
        let amount = (q.firstMatch(of: /\$\s*(\d+(?:[.,]\d+)?)/)?.1 ?? q.firstMatch(of: /(\d+(?:[.,]\d+)?)\s*(?:usdc|usdg|\$|долл|dollars?|bucks|бакс)/)?.1)
            .flatMap { Decimal(string: String($0).replacingOccurrences(of: ",", with: ".")) }
        // «положи 1 в джупитер»: a bare number is the amount of a deposit or a withdrawal when nothing else is
        // (not for buys: «buy 0.1 SOL» is coins, not dollars).
        let bare = q.firstMatch(of: /(?:^|[^\w.,])(\d+(?:[.,]\d+)?)(?![\d.,]*\s*(?:%|x\b|х\b|×|r\b))/)
            .flatMap { Decimal(string: String($0.1).replacingOccurrences(of: ",", with: ".")) }
        let jupiter = q.contains(/jupiter|jupyter|джупитер|юпитер|\bjup\s*(?:lend|vault|earn)|jlusdc/)
        let vault = jupiter || q.contains(/хранилищ|вол[тл]|vault|\blend|депозит|лендинг/)
        let places = #"(?:the\s+|my\s+|мо[йеюи]\s+)?(?:vault|хранилищ|jupiter|jupyter|джупитер|юпитер|kamino|камино|aave|ааве|hlp|хлп|лендинг|lend)"#
        let into = q.contains(Self.depositWords) || q.contains(try! Regex(#"(?:\bв\b|\bво\b|into|\bto\b|\bin\b)\s+"# + places))
        let outOf = q.contains(Self.withdrawWords) || q.contains(try! Regex(#"(?:\bfrom\b|\bиз\b|\bс\b|\bсо\b|out\s+of)\s+"# + places))
        let coins = q.firstMatch(of: /(\d+(?:[.,]\d+)?)\s*(?:sol|сол|jitosol|usdt|jupusd|usdc)/).flatMap { Decimal(string: String($0.1).replacingOccurrences(of: ",", with: ".")) }
        // «USDC на Солане» is USDC; Solana alone is the network, SOL the coin.
        let symbol = q.contains(/usdc|юсдс|юсдц/) ? "USDC" : q.contains(/\bsol\b|\bсол\b/) ? "SOL" : q.contains(/usdt/) ? "USDT" : q.contains(/jupusd/) ? "JupUSD" : "USDC"
        if q.contains(/разлож|распредел|раскид|размест|spread|allocate|distribute|split/), q.contains(/ставк|доходн|протокол|лучш|хранилищ|rates?|yields?|protocols?|best|vaults?/) {
            let share = q.firstMatch(of: /(\d+(?:[.,]\d+)?)\s*%/).flatMap { Decimal(string: String($0.1).replacingOccurrences(of: ",", with: ".")) }
            return .allocate(q.contains(/\bsol\b|солан|\bсол\b/) ? "SOL" : "USDC", maxShare: share)
        }
        if q.contains(/доходност|где\s+(?:лучше\s+)?держать|куда\s+(?:лучше\s+)?(?:положить|вложить|деть)|\bapy\b|ставк[иа]\s+(?:по\s+)?депозит|where\s+(?:to|should\s+i|can\s+i)\s+(?:keep|put|park|hold)|best\s+(?:rates?|yields?)|\byields?\b/) {
            let sol = q.contains(/\bsol\b|солан|\bсол\b|solana/), usd = q.contains(/usdc|стейбл|доллар|stable/)
            return .yields(sol && usd ? nil : sol ? "SOL" : usd ? "USDC" : q.contains(/usdt/) ? "USDT" : nil)
        }
        // Any token by its contract («купи 0x… токен на $2»): bought on Robinhood Chain, where LALA trades by contract.
        if let contract = text.firstMatch(of: /0x[0-9a-fA-F]{40}(?![0-9a-fA-F])/).map({ String($0.0) }) {
            if q.contains(/\bsell\b|прода\w*|\bdump\b/) {
                let tokens = q.firstMatch(of: /(?:^|\s)(\d+(?:[.,]\d+)?)\s*(?:tokens?|токен\w*|шт)/).flatMap { Decimal(string: String($0.1).replacingOccurrences(of: ",", with: ".")) }
                return .sellStock(symbol: contract, amount: amount == nil ? tokens : nil)
            }
            if q.contains(/\bbuy\b|куп\w*|purchase|приобрет\w*|\bget\s+me\b|вложи\w*\s+в/) { return .buyStock(symbol: contract, usdc: amount) }
        }
        // Robinhood Stock Tokens: a stock word or a company LALA knows, with buy or sell.
        if let symbol = StockNames.symbol(in: text), q.contains(/\bstocks?\b|\bshares?\b|акци\w*|токен\w*|robinhood|робинхуд|спейс|spacex|\btesla\b|тесл|нвид|nvidia/) {
            if q.contains(/\bsell\b|прода\w*|\bdump\b/) {
                let shares = q.firstMatch(of: /(\d+(?:[.,]\d+)?)\s*(?:shares?|акци\w*|tokens?|токен\w*|[a-z]{2,5}\b)/).flatMap { Decimal(string: String($0.1).replacingOccurrences(of: ",", with: ".")) }
                return .sellStock(symbol: symbol, amount: amount == nil ? shares : nil)
            }
            if q.contains(/\bbuy\b|куп\w*|purchase|приобрет\w*|\bget\s+me\b|вложи\w*\s+в/) { return .buyStock(symbol: symbol, usdc: amount) }
        }
        // Out of the Solana wallet: «move 3 USDC from Solana to Robinhood», «переведи 3 USDC из соланы в робингуд».
        if let m = q.firstMatch(of: /(?:\bfrom\b|\bиз\b|\bс\b|\bсо\b)\s+(?:the\s+|my\s+)?(?:solana|солан\w*)(?:[^.]|\.(?=\d))*?(?:\bto\b|\binto\b|\bв\b|\bна\b)\s+(?:the\s+)?(base|бейс\w*|arbitrum|арбитрум\w*|robinhood|робин[гх]уд\w*)/) {
            let place = String(m.1)
            return .solanaTo(place.hasPrefix("b") || place.hasPrefix("бейс") ? "base" : place.hasPrefix("arb") || place.hasPrefix("арб") ? "arbitrum" : "robinhood", amount)
        }
        if q.contains(/robinhood|робин[гх]уд/), q.contains(/(?:выв[её]д\w*|верн\w*|перевед\w*|перенес\w*|withdraw\w*|move|send|bring|bridge)(?:[^.]|\.(?=\d))*(?:solana|солан)/) {
            return .robinhoodToSolana(amount)
        }
        // Topping LALA up from outside: a deposit with no place to put it, or asking for our address.
        let place = q.contains(/хранилищ|vault|jupiter|jupyter|джупитер|юпитер|kamino|камино|aave|ааве|morpho|морфо|hlp|хлп|\blend|лендинг|стейк|stake/)
        if !place, q.contains(/^\s*(?:(?:хочу|want\s+to|i\s+want\s+to|let'?s|давай)\s+)?(?:задепозит\w*|депозит\w*|пополн\w*|deposit|top\s*up|fund|receive|закинуть\s+деньги)\b|(?:мо[йи]|наш\w*|our|my|lala'?s?)\s+(?:\w+\s+)?(?:адрес\w*|address(?:es)?)|deposit\s+address|адрес\w*\s+(?:для\s+)?(?:пополнен|депозит)|куда\s+(?:мне\s+)?(?:от)?(?:прав|слать|кин|закин|переве)|where\s+(?:do\s+i|to|can\s+i|should\s+i)\s+(?:send|deposit|transfer)|how\s+(?:do\s+i|to|can\s+i)\s+(?:top\s+up|deposit|fund|add\s+money)|как\s+(?:мне\s+)?пополн/) {
            return .receive
        }
        if q.contains(/анстейк|unstake|из\s+стейкинга|продай\w*\s+(?:весь\s+)?jitosol/) { return .unstake(coins) }
        if q.contains(/застейк|стейкни|\bstake\b|в\s+стейкинг/) { return .stake(coins ?? amount) }
        if q.contains(/\bhlp\b|хлп/) {
            if outOf { return .hlp(deposit: false, amount: coins ?? amount ?? bare) }
            if into { return .hlp(deposit: true, amount: coins ?? amount ?? bare) }
        }
        if q.contains(/\baave\b|ааве|\bаав/) {
            if outOf { return .aave(deposit: false, amount: coins ?? amount ?? bare) }
            // Only with a word for putting money in: «what do I have on Aave?» is a question.
            if into || q.contains(/\blend\b|\bsupply\b|\bbuy\b|\bкуп\w*|одолж/) { return .aave(deposit: true, amount: coins ?? amount ?? bare) }
        }
        if q.contains(/morpho|морфо|gauntlet/) {
            if outOf { return .morpho(deposit: false, amount: coins ?? amount ?? bare) }
            if into || q.contains(/\blend\b|\bsupply\b|\bdeposit\b|депозит|полож|одолж/) { return .morpho(deposit: true, amount: coins ?? amount ?? bare) }
        }
        if q.contains(/kamino|камино/) {
            if outOf { return .kamino(deposit: false, symbol: symbol, amount: coins ?? amount ?? bare) }
            if into { return .kamino(deposit: true, symbol: symbol, amount: coins ?? amount ?? bare) }
        }
        if q.contains(/(?:останов|отмен|прекрат|стоп)\w*\s+(?:регулярн\w*\s+)?(?:покупк|dca|расписан)|(?:stop|cancel|end)\s+(?:the\s+|all\s+)?(?:recurring|regular|scheduled)?\s*(?:buys|purchases|dca|schedules?)/) { return .stopSchedules }
        if q.contains(/покупай|каждый|каждую|каждые|раз\s+в\s+|регулярн|\bdca\b|\bevery\b|\beach\b|weekly|daily|monthly|recurring/), q.contains(/куп|dca|\bbuy/), let asset = SpotAsset.find(q), let amount {
            let days: Int
            if q.contains(/день|сутки|ежедневн|daily|every\s+day|each\s+day/) && !q.contains(/каждые\s+\d|every\s+\d/) { days = 1 }
            else if let m = q.firstMatch(of: /(?:каждые|every)\s+(\d+)\s*(?:дн|день|сут|days?)/), let n = Int(m.1) { days = n }
            else if q.contains(/месяц|monthly/) { days = 30 }
            else { days = 7 }
            return .schedule(asset, usdc: amount, days: days)
        }
        // «закрой NEAR-аккаунт и переведи всё на Bybit», «close the NEAR account into Bybit»: the last «на / to / into» names it.
        if q.contains(/(?:close|delete|закр\w*|удали\w*)\s+(?:(?:the|my|мой)\s+)?(?:near|неар\w*)[\s-]*(?:account|аккаунт\w*)/),
           let m = text.firstMatch(of: /(?i).*\s(?:into|to|на|в)\s+[«"“]?(.+?)[»"”]?\s*[.!]?$/) {
            return .closeNear(name: String(m.1).trimmingCharacters(in: .whitespaces))
        }
        // «отправь 0.001 SOL на Old wallet», «send 0.01 SOL to Bybit»: native SOL to a saved Solana address.
        if let m = text.firstMatch(of: /(?i)(?:send|transfer|отправь\w*|переведи|перевести|скинь|кинь)\s+(\d+(?:[.,]\d+)?)\s*(?:sol|сол\w*)\s+(?:to|на|для)\s+[«"“]?(.+?)[»"”]?\s*[.!]?$/),
           let value = Decimal(string: String(m.1).replacingOccurrences(of: ",", with: ".")) {
            let name = String(m.2).trimmingCharacters(in: .whitespaces)
            // «send 1 SOL to Jupiter / the vault» is a deposit, not a transfer to someone.
            if name.lowercased().wholeMatch(of: /(?:the\s+)?(?:vault|jupiter\w*|kamino|jito\w*|хранилищ\w*|джупитер\w*|камино)/) == nil {
                return .sendSol(name: name, amount: value)
            }
        }
        // «отправь 0.05 NEAR на Bybit», «send all NEAR to Bybit»: a number or «all» is required — never guessed.
        if let m = text.firstMatch(of: /(?i)(?:send|transfer|move|отправь\w*|переведи|перевести|скинь|кинь)\s+((?:all|весь|всё|все)\s+(?:(?:the|my|мой|мои)\s+)?)?(?:(\d+(?:[.,]\d+)?)\s*)?(?:near|неар\w*|ниар\w*)\s+(?:to|на|для)\s+[«"“]?(.+?)[»"”]?\s*[.!]?$/),
           m.1 != nil || m.2 != nil {
            let amount = m.2.flatMap { Decimal(string: String($0).replacingOccurrences(of: ",", with: ".")) }
            return .sendNear(name: String(m.3).trimmingCharacters(in: .whitespaces), amount: amount)
        }
        // «near» is also a word: «buy ETH near 2500» is a limit on ETH, not the NEAR token.
        if q.contains(/\bкуп\w*|\bbuy\b/), q.contains(/\bnear\b(?!\s*\$?\d)|\bнеар\w*|\bниар\w*|\bнир\b/), SpotAsset.find(q) == nil,
           !q.contains(/\b(?:long|short|лонг\w*|шорт\w*|perp\w*)\b/) {
            // «на 3» / «for 3» is dollars; «buy 2 NEAR» is coins and is not guessed.
            let forDollars = q.firstMatch(of: /(?:\bна|\bfor)\s+(\d+(?:[.,]\d+)?)/).flatMap { Decimal(string: String($0.1).replacingOccurrences(of: ",", with: ".")) }
            return .buyNear(usdc: amount ?? forDollars)
        }
        // «продай неар», «sell 0.5 NEAR»: native NEAR to USDC on Solana; no number = all of it.
        if q.contains(/продай\w*|продать|\bsell\b/), q.contains(/\bnear\b|\bнеар\w*|\bниар\w*|\bнир\b/), SpotAsset.find(q) == nil,
           !q.contains(/\b(?:long|short|лонг\w*|шорт\w*|perp\w*)\b/) {
            let coins = q.firstMatch(of: /(\d+(?:[.,]\d+)?)\s*(?:near|неар\w*|ниар\w*)/).flatMap { Decimal(string: String($0.1).replacingOccurrences(of: ",", with: ".")) }
            return .sellNear(amount: coins)
        }
        if q.contains(/\bкуп\w*|\bbuy\b/), let asset = SpotAsset.find(q) { return .buy(asset, usdc: amount) }
        if q.contains(/продай\w*|продать|\bsell\b/), let asset = SpotAsset.find(q) {
            let coins = q.firstMatch(of: /(\d+(?:[.,]\d+)?)\s*(?:sol|btc|eth|jup|сол|битк|эфир)/).flatMap { Decimal(string: $0.1.replacingOccurrences(of: ",", with: ".")) }
            return .sell(asset, amount: coins)
        }
        if vault, outOf || q.contains(/достан\w*/) { return .lendWithdraw(symbol, coins ?? amount ?? bare) }
        if vault, into || q.contains(/^\s*lend\b/) { return .lendDeposit(symbol, coins ?? amount ?? bare) }
        // «jupiter vault 1 USDC» without a verb.
        if jupiter, let value = coins ?? amount { return .lendDeposit(symbol, value) }
        if let m = text.firstMatch(of: /(?i)(?:send|pay|transfer|отправь\w*|переведи|перевести|скинь|кинь)\s+\$?(\d+(?:[.,]\d+)?)\s*(?:usdc|\$|долл\w*|dollars?|bucks)?\s+(?:to|на|для)\s+[«"“]?(.+?)[»"”]?\s*[.!]?$/),
           let value = Decimal(string: String(m.1).replacingOccurrences(of: ",", with: ".")) {
            let name = String(m.2).trimmingCharacters(in: .whitespaces)
            // Our own places stay what they were; a pasted address is not a name.
            let place = name.lowercased().wholeMatch(of: /(?:the\s+)?(?:solana|солан\w*|hyperliquid|хайперликвид\w*|base|бейс|aave|kamino|hlp|vault)/) != nil
            if !place, !name.lowercased().contains(/0x[0-9a-f]{6}/), name.count <= 40 {
                return .sendTo(name: name, amount: value)
            }
        }
        if q.contains(/arbitrum|арбитрум/), q.contains(/(?:выв[её]д\w*|верн\w*|перевед\w*|перенес\w*|withdraw\w*|move|send|bring|bridge)(?:[^.]|\.(?=\d))*(?:solana|солан)/) {
            return .arbitrumToSolana(amount)
        }
        if q.contains(/\bbase\b|бейс/), q.contains(/(?:выв[её]д\w*|верн\w*|перевед\w*|перенес\w*|withdraw\w*|move|send|bring|bridge)(?:[^.]|\.(?=\d))*(?:solana|солан)/) {
            return .baseToSolana(amount)
        }
        // «…to Solana» from Hyperliquid; «из соланы» is the other direction and never lands here.
        if !vault, !q.contains(/(?:\bfrom\b|\bиз\b|\bс\b|\bсо\b)\s+(?:the\s+|my\s+)?(?:solana|солан)/),
           q.contains(/(?:выв[её]д\w*|верн\w*|перевед\w*|withdraw\w*|move|send|bring)(?:[^.]|\.(?=\d))*(?:solana|солан)/) { return .withdrawToSolana(amount) }
        return nil
    }

    nonisolated(unsafe) static let depositWords = try! Regex("полож\\w*|внес\\w*|закин\\w*|вкин\\w*|кинь|засун\\w*|влож\\w*|задепозит\\w*|депозитн\\w*|депни|пополн\\w*|инвест\\w*|\\bdeposit\\w*|\\bdepo\\b|\\bput\\b|\\badd\\b|\\bplace\\b|\\bsupply\\b|\\bstash\\b|\\bpark\\b|\\binvest\\w*|\\btop\\s+up\\b")
    nonisolated(unsafe) static let withdrawWords = try! Regex("сним\\w*|выв[её]д\\w*|забер\\w*|верн\\w*|\\bwithdraw\\w*|take\\s+out|\\bremove\\b|\\bpull\\b|\\bredeem\\w*")
}

/// A regular purchase the app carries out while it is open.
public struct Schedule: Codable, Equatable, Sendable {
    public let symbol: String
    public let usdc: Decimal
    public let days: Int
    public var next: Date

    public init(symbol: String, usdc: Decimal, days: Int, next: Date) {
        self.symbol = symbol
        self.usdc = usdc
        self.days = days
        self.next = next
    }

    public var asset: SpotAsset? { SpotAsset.all.first { $0.symbol == symbol } }

    /// After a run: the next date strictly in the future, so a long pause does not buy several times at once.
    public mutating func advance(now: Date = Date()) {
        repeat { next = next.addingTimeInterval(TimeInterval(days) * 86_400) } while next <= now
    }
}

extension WalletCommand {
    /// A deposit, a buy or a stake that came without an amount: the chat asks, and the next answer fills it.
    public var amountQuestion: String? {
        switch self {
        case .lendDeposit(let s, nil): "How much \(s) into Jupiter Lend?"
        case .kamino(true, let s, nil): "How much \(s) into Kamino?"
        case .hlp(true, nil): "How much USDC into HLP? (at least $5)"
        case .aave(true, nil): "How much USDC into Aave on Base?"
        case .morpho(true, nil): "How much USDC into Morpho on Base?"
        case .buy(let a, nil): "For how many USDC should I buy \(a.symbol)?"
        case .buyNear(nil): "For how many USDC should I buy NEAR?"
        case .buyStock(let s, nil): "For how many USDC should I buy \(s)?"
        case .stake(nil): "How much SOL to stake?"
        case .solanaTo(let place, nil): "How many USDC should I move from Solana to \(Self.placeName(place))?"
        default: nil
        }
    }

    public func with(amount: Decimal) -> WalletCommand {
        switch self {
        case .lendDeposit(let s, _): .lendDeposit(s, amount)
        case .kamino(let d, let s, _): .kamino(deposit: d, symbol: s, amount: amount)
        case .hlp(let d, _): .hlp(deposit: d, amount: amount)
        case .aave(let d, _): .aave(deposit: d, amount: amount)
        case .morpho(let d, _): .morpho(deposit: d, amount: amount)
        case .buy(let a, _): .buy(a, usdc: amount)
        case .buyNear: .buyNear(usdc: amount)
        case .buyStock(let s, _): .buyStock(symbol: s, usdc: amount)
        case .stake: .stake(amount)
        case .solanaTo(let place, _): .solanaTo(place, amount)
        default: self
        }
    }

    static func placeName(_ place: String) -> String {
        ["base": "Base", "arbitrum": "Arbitrum", "robinhood": "Robinhood Chain"][place] ?? place.capitalized
    }

    /// «1», «1 USDC», «$1.5», «да, 2», «ok 3» — a short reply that is only an amount.
    public static func amountAnswer(_ text: String) -> Decimal? {
        let q = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let m = q.wholeMatch(of: /(?:(?:да|yes|ok|окей|давай|го|sure|yep|угу)[,!\s]*)?(?:на\s+|for\s+)?\$?\s*(\d+(?:[.,]\d+)?)\s*(?:usdc|\$|долл\w*|dollars?|bucks|sol|сол|юсдс)?\s*[.!]?/) else { return nil }
        return Decimal(string: String(m.1).replacingOccurrences(of: ",", with: ".")).flatMap { $0 > 0 ? $0 : nil }
    }

    /// In words, for the confirm button and the reply: «deposit 1 USDC into Jupiter Lend».
    public var summary: String {
        func n(_ d: Decimal?) -> String { d.map { Fmt.num($0, maxFraction: 6) } ?? "all" }
        switch self {
        case .buy(let a, let u): return "buy \(a.symbol) for \(n(u)) USDC"
        case .buyNear(let u): return "buy native NEAR for \(n(u)) USDC (to your NEAR account)"
        case .sellNear(let x): return "sell \(n(x)) NEAR from your NEAR account for USDC on Solana"
        case .sell(let a, let x): return "sell \(n(x)) \(a.symbol)"
        case .schedule(let a, let u, let d): return "buy \(a.symbol) for \(Fmt.num(u)) USDC every \(d == 1 ? "day" : d == 7 ? "week" : "\(d) days")"
        case .stopSchedules: return "stop recurring buys"
        case .withdrawToSolana(let u): return "withdraw \(n(u)) USDC from Hyperliquid to Solana"
        case .lendDeposit(let s, let x): return "deposit \(n(x)) \(s) into Jupiter Lend"
        case .lendWithdraw(let s, let x): return "withdraw \(n(x)) \(s) from Jupiter Lend"
        case .kamino(let d, let s, let x): return d ? "deposit \(n(x)) \(s) into Kamino" : "withdraw \(n(x)) \(s) from Kamino"
        case .stake(let x): return "stake \(n(x)) SOL (→ JitoSOL)"
        case .unstake(let x): return "unstake \(n(x)) JitoSOL"
        case .yields(let a): return "rates for \(a ?? "USDC and SOL")"
        case .hlp(let d, let x): return d ? "deposit \(n(x)) USDC into HLP" : "withdraw \(n(x)) USDC from HLP"
        case .allocate(let s, let share): return "spread \(s) across the best rates" + (share.map { " (max \(Fmt.num($0))% per protocol)" } ?? "")
        case .aave(let d, let x): return d ? "deposit \(n(x)) USDC into Aave on Base" : "withdraw \(n(x)) USDC from Aave to Solana"
        case .morpho(let d, let x): return d ? "deposit \(n(x)) USDC into Morpho on Base" : "withdraw \(n(x)) USDC from Morpho to Solana"
        case .baseToSolana(let x): return "move \(n(x)) USDC from Base to Solana"
        case .arbitrumToSolana(let x): return "move \(n(x)) USDC from Arbitrum to Solana"
        case .sendTo(let name, let x): return "send \(Fmt.num(x)) USDC to \(name)"
        case .sendNear(let name, let x): return "send \(n(x)) NEAR to \(name)"
        case .closeNear(let name): return "close your NEAR account and send all its NEAR to \(name)"
        case .sendSol(let name, let x): return "send \(Fmt.num(x, maxFraction: 9)) SOL to \(name)"
        case .receive: return "show where to top up"
        case .buyStock(let s, let u): return "buy \(s.hasPrefix("0x") ? "the token \(s)" : "\(s) stock tokens") for \(n(u)) USDC on Robinhood Chain"
        case .sellStock(let s, let x): return "sell \(n(x)) \(s.hasPrefix("0x") ? "of the token \(s)" : "\(s) stock tokens") on Robinhood Chain"
        case .robinhoodToSolana(let x): return "move \(n(x)) USDG from Robinhood Chain to Solana"
        case .solanaTo(let place, let x): return "move \(n(x)) USDC from Solana to \(Self.placeName(place))"
        }
    }
}

extension IntentParser {
    /// Whether the text can start a new trade plan: it names a market or a direction. «1 USDC» alone does not —
    /// it would otherwise turn into the default «long ETH».
    public static func startsPlan(_ text: String, markets: Set<String> = []) -> Bool {
        text.lowercased().contains(/лонг|шорт|\blong\b|\bshort\b|\bbuy\b|\bsell\b/) || namedAsset(text, markets: markets) != nil
    }
}
