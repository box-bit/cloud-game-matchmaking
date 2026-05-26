#!/bin/bash
set -e

SERVERTYPE=$([ "$SERVER_PUBLIC" = "1" ] && echo 3 || echo 1)

cat >/home/redeclipse/.redeclipse/servinit.cfg <<EOF
serverpass "$SERVER_PASS"
adminpass "$ADMIN_PASS"

if (= \$rehashing 0) [
    servertype $SERVERTYPE
    serverport $SERVER_PORT
]

sv_serverclients $MAX_PLAYERS
sv_serverdesc "$SERVER_DESC"
sv_timelimit $(( TIME_LIMIT / 60 ))
sv_pointlimit $FRAG_LIMIT
EOF

exec /usr/games/redeclipse-server -ss3
