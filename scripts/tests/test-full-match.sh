#!/bin/bash
# =============================================================================
# test-full-match.sh
# Full end-to-end match test: two players → matchmaker → SUCCEEDED + server info
# =============================================================================
# Prerequisites:
#   - sam deploy has been run
#   - scripts/get-token.sh has been run       (populates .session/)
#   - scripts/seed-test-players.sh has been run
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

step() { echo -e "\n${BLUE}▶ $1${NC}"; }
ok()   { echo -e "${GREEN}  ✅ $1${NC}"; }
fail() { echo -e "${RED}  ❌ $1${NC}"; exit 1; }
info() { echo "  $1"; }

# ── Pre-flight ────────────────────────────────────────────────────────────────
step "Pre-flight checks"

for f in ".session/api_url.txt" ".session/id_token.txt" ".session/sub.txt"; do
    [ -f "$f" ] && [ -n "$(cat "$f")" ] || fail "$f missing or empty. Run scripts/get-token.sh first."
done

API_URL=$(cat .session/api_url.txt)
ID_TOKEN=$(cat .session/id_token.txt)
SUB=$(cat .session/sub.txt)
OPPONENT_ID="test-opponent-001"

ok "Session files OK"
info "API URL  : $API_URL"
info "Player 1 : $SUB (ELO 1200)"
info "Player 2 : $OPPONENT_ID (ELO 1350)  — 150 ELO diff, within initial ±200 range"

# ── Submit Player 1 ticket via API ───────────────────────────────────────────
step "Submitting Player 1 matchmaking ticket via POST /match"

RESP=$(curl -s -w "\n%{http_code}" -X POST "$API_URL/match" \
    -H "Authorization: Bearer $ID_TOKEN")
HTTP_CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | head -n1)

[ "$HTTP_CODE" = "200" ] || fail "POST /match returned HTTP $HTTP_CODE: $BODY"

TICKET_1=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin)['ticketId'])")
ok "Player 1 ticket: $TICKET_1"

# ── Inject Player 2 ticket directly into DynamoDB ────────────────────────────
step "Injecting Player 2 ticket into DynamoDB"

NOW=$(date +%s)
TICKET_2="test-opponent-ticket-$(date +%s)"

aws dynamodb put-item \
    --table-name MatchmakingTickets \
    --item "{
        \"TicketId\":  {\"S\": \"$TICKET_2\"},
        \"UserId\":    {\"S\": \"$OPPONENT_ID\"},
        \"Status\":    {\"S\": \"SEARCHING\"},
        \"ELO\":       {\"N\": \"1350\"},
        \"CreatedAt\": {\"N\": \"$NOW\"},
        \"TTL\":       {\"N\": \"$((NOW + 3600))\"}
    }" > /dev/null

ok "Player 2 ticket: $TICKET_2"

# ── Invoke matchmaker Lambda directly (skip the 1-minute wait) ───────────────
step "Invoking MatchStatusPoller Lambda"

aws lambda invoke \
    --function-name MatchStatusPoller \
    --payload '{}' \
    /tmp/matchmaker-output.json > /dev/null

LAMBDA_RESULT=$(cat /tmp/matchmaker-output.json)
info "Lambda response: $LAMBDA_RESULT"
ok "MatchStatusPoller invoked"

# ── Poll Player 1 ticket for SUCCEEDED ───────────────────────────────────────
step "Polling Player 1 ticket status"

MAX_ATTEMPTS=5
for i in $(seq 1 $MAX_ATTEMPTS); do
    RESP=$(curl -s -w "\n%{http_code}" "$API_URL/match/$TICKET_1" \
        -H "Authorization: Bearer $ID_TOKEN")
    HTTP_CODE=$(echo "$RESP" | tail -n1)
    BODY=$(echo "$RESP" | head -n1)

    STATUS=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null)
    info "Attempt $i: status=$STATUS"

    if [ "$STATUS" = "SUCCEEDED" ]; then
        SERVER_IP=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('serverIp',''))" 2>/dev/null)
        SERVER_PORT=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('serverPort',''))" 2>/dev/null)
        MATCHED=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('matchedPlayers',''))" 2>/dev/null)
        ok "Match found!"
        echo ""
        echo -e "  ${GREEN}Matched players : $MATCHED${NC}"
        echo -e "  ${GREEN}Server address  : $SERVER_IP:$SERVER_PORT${NC}"
        break
    fi

    [ "$i" = "$MAX_ATTEMPTS" ] && fail "Ticket still not SUCCEEDED after $MAX_ATTEMPTS attempts. Run: sam logs -n MatchStatusPoller --tail"
    sleep 2
done

# ── Check Player 2 ticket in DynamoDB ────────────────────────────────────────
step "Verifying Player 2 ticket status in DynamoDB"

P2_STATUS=$(aws dynamodb get-item \
    --table-name MatchmakingTickets \
    --key "{\"TicketId\": {\"S\": \"$TICKET_2\"}}" \
    --query "Item.Status.S" \
    --output text)

if [ "$P2_STATUS" = "SUCCEEDED" ]; then
    ok "Player 2 ticket also SUCCEEDED"
else
    echo -e "${YELLOW}  ⚠ Player 2 ticket status: $P2_STATUS (expected SUCCEEDED)${NC}"
fi

# ── EC2 server reachability ───────────────────────────────────────────────────
step "Checking EC2 game server reachability"

if [ -n "$SERVER_IP" ]; then
    info "Testing TCP reachability of $SERVER_IP (port 22 as a proxy for instance up)..."
    if nc -z -w 3 "$SERVER_IP" 22 2>/dev/null; then
        ok "EC2 instance is reachable (TCP 22 open)"
    else
        echo -e "${YELLOW}  ⚠ TCP 22 not reachable — instance may still be booting or SSH is blocked${NC}"
    fi

    info ""
    info "To verify the Red Eclipse server process, SSH into the instance:"
    info "  ssh -i <your-key.pem> ubuntu@$SERVER_IP"
    info "  sudo systemctl status redeclipse-server"
    info ""
    info "To connect with the Red Eclipse game client, add this server:"
    info "  Address : $SERVER_IP"
    info "  Port    : $SERVER_PORT"
else
    echo -e "${YELLOW}  ⚠ No server IP in ticket — check MatchStatusPoller logs${NC}"
fi

# ── Cleanup ───────────────────────────────────────────────────────────────────
step "Cleaning up test opponent ticket"
aws dynamodb delete-item \
    --table-name MatchmakingTickets \
    --key "{\"TicketId\": {\"S\": \"$TICKET_2\"}}" > /dev/null
ok "Opponent ticket removed"

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Full match test complete.${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo ""
