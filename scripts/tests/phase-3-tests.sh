#!/bin/bash
# =============================================================================
# phase-3-tests.sh
# End-to-end test suite for Phase 3 (custom matchmaking integration)
# =============================================================================
# Prerequisites:
#   - sam deploy has been run
#   - scripts/create-cognito-test-users.sh has been run
#   - scripts/get-token.sh has been run  (populates .session/)
#   - scripts/seed-test-players.sh has been run
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASSED=0
FAILED=0

print_header() {
    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
}

print_test() {
    echo ""
    echo -e "${YELLOW}▶ TEST $1: $2${NC}"
}

pass() {
    echo -e "${GREEN}  ✅ PASSED — $1${NC}"
    PASSED=$((PASSED + 1))
}

fail() {
    echo -e "${RED}  ❌ FAILED — $1${NC}"
    FAILED=$((FAILED + 1))
}

print_response() {
    echo "  Response: $1"
}

# ── Pre-flight Checks ─────────────────────────────────────────────────────────
print_header "Pre-flight Checks"

for f in ".session/api_url.txt" ".session/id_token.txt" ".session/sub.txt"; do
    if [ ! -f "$f" ] || [ -z "$(cat "$f")" ]; then
        echo -e "${RED}❌ $f is missing or empty. Run scripts/get-token.sh first.${NC}"
        exit 1
    fi
done

API_URL=$(cat .session/api_url.txt)
ID_TOKEN=$(cat .session/id_token.txt)
SUB=$(cat .session/sub.txt)

echo -e "${GREEN}  ✅ Session files found.${NC}"
echo "  API URL : $API_URL"
echo "  Sub     : $SUB"

# Ensure the test player profile exists
aws dynamodb put-item \
    --table-name PlayerProfiles \
    --item "{
        \"UserId\": {\"S\": \"$SUB\"},
        \"ELO\":    {\"N\": \"1200\"},
        \"Wins\":   {\"N\": \"10\"},
        \"Losses\": {\"N\": \"5\"}
    }" > /dev/null
echo "  Player profile ensured in DynamoDB."

# =============================================================================
# TEST 1 — POST /match creates a matchmaking ticket
# =============================================================================
print_header "Test 1 — Start Matchmaking"
print_test "1" "POST /match should return 200 with ticketId and status=SEARCHING"

RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$API_URL/match" \
    -H "Authorization: Bearer $ID_TOKEN")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n1)
print_response "HTTP $HTTP_CODE — $BODY"

TICKET_ID=""
if [ "$HTTP_CODE" = "200" ]; then
    TICKET_ID=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ticketId',''))" 2>/dev/null)
    STATUS=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null)
    HAS_ELO=$(echo "$BODY" | python3 -c "import sys,json; print('yes' if 'elo' in json.load(sys.stdin) else 'no')" 2>/dev/null)

    if [ -n "$TICKET_ID" ] && [ "$STATUS" = "SEARCHING" ] && [ "$HAS_ELO" = "yes" ]; then
        pass "Ticket created. ticketId=$TICKET_ID  status=$STATUS  elo ✓"
    else
        fail "HTTP 200 but body missing expected fields. Got: $BODY"
    fi
else
    fail "Expected HTTP 200, got HTTP $HTTP_CODE. Check sam logs -n StartMatchmaking --tail"
fi

if [ -z "$TICKET_ID" ]; then
    echo -e "${RED}Cannot continue without a ticketId. Aborting remaining tests.${NC}"
    exit 1
fi

# =============================================================================
# TEST 2 — GET /match/{ticketId} returns ticket owned by this player
# =============================================================================
print_header "Test 2 — Get Match Status"
print_test "2" "GET /match/{ticketId} should return 200 with current status"

RESPONSE=$(curl -s -w "\n%{http_code}" -X GET "$API_URL/match/$TICKET_ID" \
    -H "Authorization: Bearer $ID_TOKEN")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n1)
print_response "HTTP $HTTP_CODE — $BODY"

if [ "$HTTP_CODE" = "200" ]; then
    STATUS=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null)
    RETURNED_TICKET=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ticketId',''))" 2>/dev/null)

    if [ "$RETURNED_TICKET" = "$TICKET_ID" ] && [ -n "$STATUS" ]; then
        pass "Ticket retrieved. ticketId ✓  status=$STATUS"
    else
        fail "HTTP 200 but unexpected body. Got: $BODY"
    fi
else
    fail "Expected HTTP 200, got HTTP $HTTP_CODE."
fi

# =============================================================================
# TEST 3 — GET /match/{ticketId} is forbidden for a different user
# =============================================================================
print_header "Test 3 — Ownership Enforcement"
print_test "3" "GET /match/{ticketId} with a spoofed ticketId should return 403 or 404"

# Inject a ticket owned by a different user
FAKE_TICKET="fake-ticket-$(date +%s)"
aws dynamodb put-item \
    --table-name MatchmakingTickets \
    --item "{
        \"TicketId\": {\"S\": \"$FAKE_TICKET\"},
        \"UserId\":   {\"S\": \"other-user-sub-not-yours\"},
        \"Status\":   {\"S\": \"SEARCHING\"},
        \"ELO\":      {\"N\": \"1000\"}
    }" > /dev/null

RESPONSE=$(curl -s -w "\n%{http_code}" -X GET "$API_URL/match/$FAKE_TICKET" \
    -H "Authorization: Bearer $ID_TOKEN")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n1)
print_response "HTTP $HTTP_CODE — $BODY"

if [ "$HTTP_CODE" = "403" ]; then
    pass "Ownership check enforced — got 403 for another user's ticket."
else
    fail "Expected HTTP 403, got HTTP $HTTP_CODE."
fi

# Clean up fake ticket
aws dynamodb delete-item --table-name MatchmakingTickets \
    --key "{\"TicketId\": {\"S\": \"$FAKE_TICKET\"}}" > /dev/null

# =============================================================================
# TEST 4 — DELETE /match/{ticketId} cancels the ticket
# =============================================================================
print_header "Test 4 — Cancel Matchmaking"
print_test "4" "DELETE /match/{ticketId} should return 200 and set status to CANCELLED"

RESPONSE=$(curl -s -w "\n%{http_code}" -X DELETE "$API_URL/match/$TICKET_ID" \
    -H "Authorization: Bearer $ID_TOKEN")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n1)
print_response "HTTP $HTTP_CODE — $BODY"

if [ "$HTTP_CODE" = "200" ]; then
    RETURNED_TICKET=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ticketId',''))" 2>/dev/null)
    if [ "$RETURNED_TICKET" = "$TICKET_ID" ]; then
        pass "Ticket cancelled. ticketId ✓"
    else
        fail "HTTP 200 but unexpected body. Got: $BODY"
    fi
else
    fail "Expected HTTP 200, got HTTP $HTTP_CODE. Check sam logs -n CancelMatch --tail"
fi

# =============================================================================
# TEST 5 — GET /match/{ticketId} reflects CANCELLED status
# =============================================================================
print_header "Test 5 — Cancelled Status Reflected"
print_test "5" "GET /match/{ticketId} after cancel should return status=CANCELLED"

# Brief pause to allow DynamoDB write to propagate
sleep 1

RESPONSE=$(curl -s -w "\n%{http_code}" -X GET "$API_URL/match/$TICKET_ID" \
    -H "Authorization: Bearer $ID_TOKEN")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n1)
print_response "HTTP $HTTP_CODE — $BODY"

if [ "$HTTP_CODE" = "200" ]; then
    STATUS=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null)
    if [ "$STATUS" = "CANCELLED" ]; then
        pass "Status correctly updated to CANCELLED."
    else
        fail "Expected status=CANCELLED, got status=$STATUS."
    fi
else
    fail "Expected HTTP 200, got HTTP $HTTP_CODE."
fi

# =============================================================================
# TEST 6 — DELETE on an already-cancelled ticket returns 409
# =============================================================================
print_header "Test 6 — Double Cancel Rejected"
print_test "6" "DELETE on a CANCELLED ticket should return 409 Conflict"

RESPONSE=$(curl -s -w "\n%{http_code}" -X DELETE "$API_URL/match/$TICKET_ID" \
    -H "Authorization: Bearer $ID_TOKEN")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n1)
print_response "HTTP $HTTP_CODE — $BODY"

if [ "$HTTP_CODE" = "409" ]; then
    pass "409 returned for double-cancel."
else
    fail "Expected HTTP 409, got HTTP $HTTP_CODE."
fi

# =============================================================================
# TEST 7 — GET /match/nonexistent-id returns 404
# =============================================================================
print_header "Test 7 — Unknown Ticket"
print_test "7" "GET /match/nonexistent should return 404"

RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X GET \
    "$API_URL/match/this-ticket-does-not-exist-abc123" \
    -H "Authorization: Bearer $ID_TOKEN")
print_response "HTTP $RESPONSE"

if [ "$RESPONSE" = "404" ]; then
    pass "404 returned for unknown ticketId."
else
    fail "Expected HTTP 404, got HTTP $RESPONSE."
fi

# =============================================================================
# SUMMARY
# =============================================================================
print_header "Test Summary"
TOTAL=$((PASSED + FAILED))
echo "  Ran     : $TOTAL tests"
echo -e "  ${GREEN}Passed  : $PASSED${NC}"
echo -e "  ${RED}Failed  : $FAILED${NC}"
echo ""
echo -e "${YELLOW}  NOTE: A full end-to-end match (SUCCEEDED) requires two authenticated${NC}"
echo -e "${YELLOW}  players with tickets in DynamoDB. The MatchStatusPoller Lambda runs${NC}"
echo -e "${YELLOW}  every minute and matches compatible players automatically.${NC}"
echo -e "${YELLOW}  Monitor matchmaker activity with:${NC}"
echo -e "${YELLOW}    sam logs -n MatchStatusPoller --tail${NC}"
echo ""

if [ "$FAILED" = "0" ]; then
    echo -e "${GREEN}  All tests passed. Phase 3 matchmaking integration is working.${NC}"
else
    echo -e "${RED}  ⚠️  Some tests failed. Check the output above.${NC}"
    echo -e "${YELLOW}     Tip: sam logs -n StartMatchmaking --tail${NC}"
fi

echo ""
