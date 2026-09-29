#!/bin/bash
# Ledger emulator (Speculos in Docker), fixed test seed, APDU 127.0.0.1:9999 + REST 127.0.0.1:5000: speculos.sh eth|sol [nanosp|flex] | stop
set -euo pipefail
C=ihc-speculos
DIR="$HOME/Library/Caches/ihatecrypto-speculos"
SEED="abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
case "${1:-}" in
  stop) docker rm -f $C >/dev/null 2>&1 || true; exit 0 ;;
  eth) repo=app-ethereum ;;
  sol) repo=app-solana ;;
  *) echo "usage: $0 eth|sol [nanosp|flex] | stop" >&2; exit 2 ;;
esac
model=${2:-nanosp}
case $model in
  nanosp) sdk=NANOSP_SDK target=nanos2 ;;
  flex) sdk=FLEX_SDK target=flex ;;
  *) echo "model: nanosp|flex" >&2; exit 2 ;;
esac
elf="$1-$model.elf"
if [ ! -f "$DIR/apps/$elf" ]; then
  echo "building $elf..."
  [ -d "$DIR/$repo" ] || git clone -q --depth 1 "https://github.com/LedgerHQ/$repo" "$DIR/$repo"
  [ "$repo" = app-solana ] || git -C "$DIR/$repo" submodule update -q --init --depth 1 ethereum-plugin-sdk
  docker run --rm -v "$DIR/$repo:/app" -w /app ghcr.io/ledgerhq/ledger-app-builder/ledger-app-builder-lite:latest \
    sh -c "make BOLOS_SDK=\$$sdk -j8" >"$DIR/build-$elf.log" 2>&1 || { tail -20 "$DIR/build-$elf.log"; exit 1; }
  mkdir -p "$DIR/apps" && cp "$DIR/$repo/build/$target/bin/app.elf" "$DIR/apps/$elf"
fi
docker rm -f $C >/dev/null 2>&1 || true
docker run --rm -d --name $C -v "$DIR/apps:/apps:ro" -p 127.0.0.1:9999:9999 -p 127.0.0.1:5000:5000 \
  ghcr.io/ledgerhq/speculos:latest --model "$model" "/apps/$elf" --seed "$SEED" \
  --display headless --apdu-port 9999 --api-port 5000 >/dev/null
# Docker's port proxy accepts at once, so wait for speculos itself to say it listens.
for _ in $(seq 60); do
  docker logs $C 2>&1 | grep -q "Server started on 0.0.0.0:9999" && { echo "$elf ready on 127.0.0.1:9999 (REST :5000)"; exit 0; }
  docker inspect $C >/dev/null 2>&1 || { echo "speculos exited" >&2; exit 1; }
  sleep 0.5
done
docker logs $C 2>&1 | tail -20; exit 1
