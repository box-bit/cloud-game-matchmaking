#!/bin/bash
set -e

cat > /home/redeclipse/.redeclipse/servinit.cfg << EOF
serverip ""
serverport ${SERVER_PORT}
maxplayers ${MAX_PLAYERS}
serverdesc "${SERVER_DESC}"
serverpublic ${SERVER_PUBLIC}
serverpass "${SERVER_PASS}"
// 0 = deathmatch (free-for-all), no mutators
mode 0
mutators 0
timelimit ${TIME_LIMIT}
fraglimit ${FRAG_LIMIT}
EOF

exec /usr/games/redeclipse -d
