#!/bin/zsh
# Dedicated VoxeLibre server for client development.
#
# Usage: tools/server.sh [extra luanti args]
#   WORLD=path  PORT=30000  override defaults.
# Log goes to tools/server.log (ignored by git). The world lives with the
# other Luanti worlds so the normal Luanti client can open it too.
set -e
HERE=${0:A:h}
WORLD=${WORLD:-"$HOME/Library/Application Support/minetest/worlds/vrdev"}
PORT=${PORT:-30000}
LUANTI=/Applications/luanti.app/Contents/MacOS/luanti
mkdir -p "$WORLD"
exec "$LUANTI" --server --gameid mineclone2 --world "$WORLD" --port "$PORT" \
  --config "$HERE/server.conf" --logfile "$HERE/server.log" "$@"
