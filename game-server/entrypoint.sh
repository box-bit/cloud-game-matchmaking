#!/bin/bash
set -e

cat > /home/redeclipse/.redeclipse/servinit.cfg << EOF
servertype 3
serverip 0.0.0.0
serverport ${SERVER_PORT}
maxplayers ${MAX_PLAYERS}
serverdesc "${SERVER_DESC}"
serverpublic ${SERVER_PUBLIC}
adminpass "${ADMIN_PASS}"
serverpass "${SERVER_PASS}"
// 0 = deathmatch (free-for-all), no mutators
mode 0
mutators 0
timelimit ${TIME_LIMIT}
fraglimit ${FRAG_LIMIT}
EOF

exec /usr/games/redeclipse-server -ss3
