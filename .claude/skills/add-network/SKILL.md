---
name: add-network
description: Подключает новую сеть (блокчейн) к ihatecrypto — после BNB Chain только когда пользователь сам назвал сеть и попросил (решение 2026-10-08) — от проверки фактов о сети до иконки, списка в Settings › Modules, моста Relay, переводов, портфеля, команд чата и релизной сборки. Use when the user says "подключи сеть", "добавь блокчейн", "добавь сеть X", "подключи X chain", "add a network", "add chain", "support <chain>", or asks to make a new EVM chain work in the app (bridge, balance, transfers, payments).
---

# Новая сеть в ihatecrypto

**После BNB Chain сеть подключается только по прямой просьбе пользователя с названием сети** (решение 2026-10-08). Самому не предлагать и не начинать — ни Avalanche, ни Arc, ни Plasma, ни Unichain, ни другие.

Итог: сеть есть в списке Settings › Modules со своей иконкой, деньги ходят Solana ⇄ сеть через Relay, баланс виден в портфеле, адреса этой сети сохраняются и принимают переводы, чат понимает сеть по-русски и по-английски, всё покрыто тестами и собрано в Release из закоммиченного кода.

Образцы в истории: `c4b0228` (Polygon и Ethereum: RPC, USDC, газ, подписант), `1fe92ff` + `454b36b` (Tempo: газ в стейблкоине, MPP-оплата, иконки, переключатель в Modules). Перед работой прочитай их диффы: `git show --stat <sha>`, потом `git show <sha> -- <file>`.

## 1. Сначала факты о сети (ничего не угадывать)

Всё проверить живыми запросами и записать дату проверки в комментарий рядом с константой.

```bash
R=<rpc>
cast chain-id --rpc-url $R; cast gas-price --rpc-url $R
cast balance 0x90F79bf6EB2c4f870365E785982E1f101E93b906 --rpc-url $R   # «родной» баланс: у Tempo это заглушка 4242…42
curl -s https://api.relay.link/chains | python3 -c "import json,sys; [print(c['id'],c['name'],c.get('httpRpcUrl'),c.get('explorerUrl'),c.get('currency',{}).get('symbol'),[(t['symbol'],t['address']) for t in c.get('erc20Currencies') or []],[(t['symbol'],(t.get('metadata') or {}).get('logoURI')) for t in c.get('featuredTokens') or []]) for c in json.load(sys.stdin)['chains'] if '<name>' in c['name'].lower()]"
```

Ответить себе:
- **chain id, RPC, explorer.** RPC должен отдавать `eth_call`, `eth_estimateGas` и receipts без ключа (у публичных нод бывают лимиты; drpc.org обычно подходит).
- **Какой доллар.** Адрес USDC (или USDG, USDC.e): тот, который доставляет Relay. Проверить `decimals()` и `symbol()` через `cast call`.
- **Чем платится газ.** Родная монета (ETH, POL) → нужны `gasFloor`, `topupUSD`, `gasCoin`. Нет родной монеты (Tempo) → `feeToken`: как сеть выбирает токен для комиссии, что возвращает `eth_getBalance`, нужен ли разовый вызов вроде `FeeManager.setUserToken`.
- **Мост.** Котировка Relay в обе стороны (`/quote/v2`, 2 USDC): какие шаги в сторону Solana (`approve` + `depositErc20` на депозитарий из `/chains`), комиссия и время. Скрипт-образец: `rq.py` в scratchpad прошлой сессии, собрать заново на 10 строк Python.
- **Blockscout.** Есть ли у сети инстанс. Если нет, баланс читается через RPC, как `Holdings.tempo`.

## 2. Чек-лист изменений (все места, которые трогала каждая сеть)

**Сеть и подписант**
- [ ] `App/Sources/Chains/EVM/EVM.swift`: `EVMRPC.<net>` и `EVMRPC.<net>USDC`, chain id в `EVMRPC.signable`. Без этого подписант откажет: «ihatecrypto doesn't sign for network N».
- [ ] `App/Tests/WalletTests/EVMTests.swift` → `signableNetworks()`: обновить ожидаемое множество.
- [ ] `App/Sources/Protocols/Relay/Relay.swift`: `Relay.Chain.<net>`.
- [ ] `App/Sources/Execution/Trade/Aave.swift`: `EVMNetwork.<net>` (name, key, rpc, usdc, relayChain, explorer, gasFloor, topupUSD, gasCoin, feeToken) и добавить в `EVMNetwork.all`. На этом держатся `ensureEVM`, `sendEVM`, `solanaToEVM`, `evmToSolana`. Если газ не в родной монете, проверь три места: `ensureEVM` (не читать `eth_getBalance`), `sendEVM` (проверка комиссии в токене), `evmToSolana` («всё» оставляет `feeReserve`).
- [ ] Новые селекторы в calldata (например, `transferWithMemo`) декодируются в `EVMCall.decode` так, чтобы подписант проверял получателя. Иначе вызов уходит как `.contract` без проверки.

**Список сетей и иконки (не забывать: иконка — всегда)**
- [ ] `App/Sources/IhatecryptoApp/Logos/<net>.png`: 256×256 RGB без прозрачности (на тёмной теме прозрачный чёрный логотип пропадает). Взять логотип Relay (`https://assets.relay.link/icons/<chainId>/light.png`) и подложить белый фон через PIL. Сам файл в Xcode добавлять не нужно: `build-app.sh` запускает `xcodegen`.
- [ ] `App/Sources/IhatecryptoCore/Modules.swift`: `ModuleNetwork` (case, `name`, `uses`, `logo`). Строка `ModuleProtocol.relay.place`: добавить сеть. Если у сети своя функция (как MPP у Tempo), завести `ModuleKind`/`ModuleProtocol` с логотипом и свести к нему `refusal(_ command:)`.
- [ ] `App/Sources/IhatecryptoApp/ModulesUI.swift` → `icon(_ k:)`: SF Symbol для нового `ModuleKind`, если он появился.
- [ ] `App/Sources/Wallet/Core/AddressCheck.swift`: `Network` (case, `title`, формат адреса в `problem`).
- [ ] `App/Sources/IhatecryptoApp/AddressBook.swift`: `AddressCheck.Network.logo`, вопрос «Which network is this 0x address on…», `Destination` в `transfer(...)`, баланс «from» в `TransferBoard`.
- [ ] `App/Sources/IhatecryptoApp/Studio.swift` → `HoldingRow.chainLogos`: значок сети на токене в портфеле.
- [ ] `App/Sources/IhatecryptoApp/Canvases.swift`: `RouteFill` (case + `color`), `outRoute`/`backRoute` (логотип брать через `ModuleNetwork(place:)?.logo`, а не хардкодом «eth»), текст про газ.
- [ ] `App/Sources/IhatecryptoApp/RouteCards.swift`: `RouteFill.accent` для нового цвета и `places` (метка «TO · <NET>» означает свой кошелёк, а не отправку чужому).
- [ ] Иконки токенов в портфеле: у `Holding.icon` должен быть URL, иначе будет кружок с буквой. Брать `featuredTokens[].metadata.logoURI` из Relay `/chains`.

**Газ — никогда не тупик (правило пользователя)**
- [ ] У сети с родной монетой (`feeToken == nil`) `EVMNetwork` задаёт `gasFloor` и `topupUSD`. Проверь, что `Relay.nativePrice(chainId:)` отдаёт цену монеты, а котировка Solana → сеть с `topupGas` довозит газ: `sendEVM` сам докупает газ перед транзакцией, которой его не хватает (`topUpGas`: с Solana, иначе Relay-своп USDC сети в монету).
- [ ] Сеть есть в форме `add gas on <…>` (PositionCommand: слова сети в разборе газа, Normalize, блок «GAS · TOP UP»). Проверка: `WalletCheck move "add gas on <сеть> for 1 USDC"` и котировка с `topupGas` без ошибок.
- [ ] Сеть без родной монеты (как Tempo) — `feeToken`, а не газ; `add gas` для неё отвечает, что пополнять нечего.

**Деньги и баланс**
- [ ] `App/Sources/Execution/Trade/Send.swift`: `Destination.<net>` → `sendEVMUSDC(units, on: .<net>, …)`.
- [ ] `App/Sources/IhatecryptoCore/Holdings.swift`: хост в `blockscout[...]` или ветка чтения через RPC. Затем добавить в `Workspace.loadHoldings` (кортеж `read`).
- [ ] При необходимости `Workspace.<net>USDC` для карточек (по образцу `tempoUSDC`).

**Блоки — обязательно, всегда (правило пользователя)**
- [ ] `App/Sources/IhatecryptoCore/Blocks.swift`: у сети своя группа в `BlockCatalog.groups` (её имя = имя сети) и в ней все варианты: мост туда и обратно, перевод на сохранённый адрес, ежемесячный перевод («every month on the 1st: …»), каждый протокол или сервис сети (свопы, депозиты, платные API). Образец — группа «Tempo».
- [ ] У каждого блока: `fill` — `RouteFill` сети, `logo` — логотип сети или протокола, `form` — что делает и сколько стоит, `example` — рабочая команда.
- [ ] Каждый `example` проверен вживую без денег: для денежных ходов — котировка или оценка газа, для платных API — `WalletCheck move "pay …"` без `--yes` должен напечатать `Price:`. Не прошёл — в блоки не попадает (у Tempo так выпали fal/OpenAI со спонсированной комиссией и StableStudio с отложенным ответом).
- [ ] В общую форму «BRIDGE · RELAY» (группа Move money) дописать сеть. `BlocksTests.everyBlockExampleParses` зелёный.

**Чат и команды**
- [ ] `App/Sources/IhatecryptoCore/PositionCommand.swift`: слова сети в `network(_:)` и `network(in:)` (англ. и рус.: «темпо», «полигон»), регулярка `solanaTo`, условие `evmToSolana`, `placeName`.
- [ ] `App/Sources/IhatecryptoCore/Normalize.swift`: формы «MOVING MONEY», `save … on <net>`, текст `places` (где живут деньги и как ходят). Если есть новые lookup-и, описать их в системном промпте.
- [ ] `App/Sources/Wallet/Check/LocalSigner.swift` (CLI `WalletCheck move`): сеть через `EVMNetwork.named`, никакого `?? .robinhood`.
- [ ] `App/Sources/LLM/Check/main.swift`: новые lookup-и в `lookup` для `--route`.

## 3. Проверка

1. `cd App && swift build && swift build --build-tests && swift test --skip-build`: все наборы зелёные. Новые тесты кладутся в `App/Tests/IhatecryptoCoreTests/<Net>Tests.swift` (разбор команд в обе стороны, по-русски и по-английски, `ModuleNetwork(place:)`, `refusal`) и в `EVMTests` (selector/decoder).
2. Модель на живых фразах: `swift run -q LLMCheck chatgpt --route "переведи 5 USDC из соланы в <сеть>" "верни всё с <сеть> на солану" "сохрани 0x… как Shop в <сеть>"`. Каждая строка должна дать `✓ parses` с правильным направлением.
3. Живые проверки без денег: `cast estimate` на transfer, approve и прочие вызовы от адреса с балансом; котировка Relay в обе стороны; `WalletCheck move "<команда>"` без `--yes`.
4. Библиотека блоков: открыть «Add block» и увидеть группу сети с логотипами (скриншот).
5. UI-сценарий в `App/Tools/uitest-scenarios.json`: бридж рисует маршрут `SOLANA → RELAY → <NET>`. Прогон: `python3 App/Tools/uitest.py <слово>` (нужен Settings › Debugging › Local debug API).
6. Скриншот Settings › Modules: `open -g ~/Applications/"ihatecrypto Dev.app" --args -openPlace settings -settingsTab modules`, затем `screencapture -l <windowID>` (id окна через `CGWindowListCopyWindowInfo`). Убедиться, что иконка видна в тёмной теме.
7. Реальные деньги — только после Confirm/Touch ID пользователя или с тестового кошелька в рамках выданного бюджета (память `ihatecrypto-uitest`). Сам никогда не подписывай с основного кошелька.

## 4. Коммит и сборка (в репозитории параллельно работают другие сессии)

- Коммитить только свои файлы через приватный индекс. Список файлов передавать через bash: zsh не разбивает `$FILES` на слова.
  ```bash
  S=<scratchpad>; cat > $S/commit.sh <<'EOF'
  set -e; S=$1; shift; rm -f $S/idx
  GIT_INDEX_FILE=$S/idx git read-tree HEAD
  GIT_INDEX_FILE=$S/idx git add "$@"
  GIT_INDEX_FILE=$S/idx git commit -q -F $S/msg.txt
  git reset -q HEAD -- "$@"
  EOF
  bash $S/commit.sh $S <files…>
  ```
- Проверить, что HEAD собирается сам по себе: `git archive HEAD | tar -x -C $S/head`, `cp -cR App/.build $S/head/App/`, затем `swift build --target IhatecryptoApp` там. Рабочая копия может не собираться из-за чужих незаконченных правок, это не твой коммит.
- Release только из HEAD: `$S/head/App/build-app.sh Release` (перед этим `pgrep -fl "xcodebuild -project"`). Предупредить другие сессии (`ListAgents` / `SendMessage`), затем `osascript -e 'tell application id "app.ihatecrypto.mac.dev" to quit'` и `open ~/Applications/"ihatecrypto Dev.app"`. Сборка — это отдельная копия «ihatecrypto Dev» (свои кошельки, данные, порт debug API 51790); рабочую `ihatecrypto.app` не закрывать и не подменять.
- Сообщение коммита — как в истории: что теперь может пользователь, чем проверено, двигались ли деньги.

## Ловушки, на которые уже наступали

- `eth_getBalance` у сети без родной монеты (Tempo) отдаёт огромную заглушку: `EVMRPC.quantity` падает с «not a number». Такой баланс не читать.
- Tempo: комиссия обычной транзакции берётся из токена только у `transfer`/`transferWithMemo` этого токена. Для остальных вызовов берётся `FeeManager.userTokens`, иначе pathUSD, которого у кошелька нет. Отсюда `chooseFeeToken` перед первым approve.
- CLI `LocalSigner.moveMoney` раньше отправлял любую неизвестную сеть в Robinhood.
- Хардкод логотипов (`"eth"` по умолчанию в `backRoute`) даёт новой сети чужую иконку.
- `HStack` сетей в Modules — одна строка: с 10+ сетями проверь ширину на скриншоте.
