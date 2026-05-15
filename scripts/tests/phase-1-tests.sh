#!/bin/bash
# =============================================================================
# test-phase1-2.sh
# End-to-end test suite for Phase 1 (Identity & Player Data)
#                        and Phase 2 (API + Lambda)
# =============================================================================
# Prerequisites:
#   - sam deploy has been run
#   - scripts/create-test-user.sh has been run
#   - scripts/get-token.sh has been run  (populates .session/)
# =============================================================================

set -e

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ── Counters ──────────────────────────────────────────────────────────────────
PASSED=0
FAILED=0

# ── Helpers ───────────────────────────────────────────────────────────────────
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

if [ ! -f ".session/api_url.txt" ] || [ -z "$(cat .session/api_url.txt)" ]; then
    echo -e "${RED}❌ .session/api_url.txt is missing or empty.${NC}"
    echo "   Run: aws cloudformation describe-stacks --stack-name matchmaking-engine \\"
    echo "          --query \"Stacks[0].Outputs[?OutputKey=='ApiEndpoint'].OutputValue\" \\"
    echo "          --output text > .session/api_url.txt"
    exit 1
fi

if [ ! -f ".session/id_token.txt" ] || [ -z "$(cat .session/id_token.txt)" ]; then
    echo -e "${RED}❌ .session/id_token.txt is missing or empty.${NC}"
    echo "   Run: bash scripts/get-token.sh"
    exit 1
fi

if [ ! -f ".session/sub.txt" ] || [ -z "$(cat .session/sub.txt)" ]; then
    echo -e "${RED}❌ .session/sub.txt is missing or empty.${NC}"
    echo "   Run: bash scripts/get-token.sh"
    exit 1
fi

API_URL=$(cat .session/api_url.txt)
ID_TOKEN=$(cat .session/id_token.txt)
SUB=$(cat .session/sub.txt)

echo -e "${GREEN}  ✅ Session files found.${NC}"
echo "  API URL : $API_URL"
echo "  Sub     : $SUB"

# =============================================================================
# TEST 1 — Unauthenticated request must be blocked by API Gateway
# =============================================================================
print_header "Test 1 — Authentication Guard"
print_test "1" "Unauthenticated request should return 401 Unauthorized"

RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API_URL/match")
print_response "HTTP $RESPONSE"

if [ "$RESPONSE" = "401" ]; then
    pass "API Gateway correctly blocked unauthenticated request."
else
    fail "Expected HTTP 401, got HTTP $RESPONSE. Check your Cognito Authorizer in API Gateway."
fi

# =============================================================================
# TEST 2 — Authenticated request with no DynamoDB record returns 404
# =============================================================================
print_header "Test 2 — Missing Player Profile"
print_test "2" "Authenticated request with no DynamoDB record should return 404"

# Temporarily delete the player record to simulate a missing profile
aws dynamodb delete-item \
    --table-name PlayerProfiles \
    --key "{\"UserId\": {\"S\": \"$SUB\"}}" \
    2>/dev/null || true

echo "  Player record deleted to simulate missing profile."

RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$API_URL/match" \
    -H "Authorization: Bearer $ID_TOKEN")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n1)

print_response "HTTP $HTTP_CODE — $BODY"

if [ "$HTTP_CODE" = "404" ]; then
    pass "Lambda correctly returned 404 for missing player profile."
else
    fail "Expected HTTP 404, got HTTP $HTTP_CODE. Check Lambda DynamoDB read logic."
fi

# =============================================================================
# TEST 3 — Full happy path: authenticated + seeded player returns 200
# =============================================================================
print_header "Test 3 — Happy Path (Full Pipeline)"
print_test "3" "Authenticated request with seeded player should return 200 with ELO and ticketId"

# Seed the player record directly (no dependency on seed.sh)
aws dynamodb put-item \
    --table-name PlayerProfiles \
    --item "{
        \"UserId\": {\"S\": \"$SUB\"},
        \"ELO\":    {\"N\": \"1200\"},
        \"Wins\":   {\"N\": \"10\"},
        \"Losses\": {\"N\": \"5\"}
    }"

echo "  Player profile seeded for sub: $SUB"

RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$API_URL/match" \
    -H "Authorization: Bearer $ID_TOKEN")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n1)

print_response "HTTP $HTTP_CODE — $BODY"

if [ "$HTTP_CODE" = "200" ]; then
    HAS_USER_ID=$(echo "$BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print('yes' if 'userId' in d else 'no')" 2>/dev/null)
    HAS_ELO=$(echo "$BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print('yes' if 'elo' in d else 'no')" 2>/dev/null)
    HAS_TICKET=$(echo "$BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print('yes' if 'ticketId' in d else 'no')" 2>/dev/null)
    ELO_VALUE=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('elo','N/A'))" 2>/dev/null)

    if [ "$HAS_USER_ID" = "yes" ] && [ "$HAS_ELO" = "yes" ] && [ "$HAS_TICKET" = "yes" ]; then
        pass "Full pipeline working. userId ✓  elo=$ELO_VALUE ✓  ticketId ✓"
    else
        fail "HTTP 200 received but response body is missing fields. Got: $BODY"
    fi
else
    fail "Expected HTTP 200, got HTTP $HTTP_CODE. Run 'sam logs -n StartMatchmaking --tail' to debug."
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

if [ "$FAILED" = "0" ]; then
    echo -e "${GREEN}  All tests passed. Phase 1 & 2 are working correctly.${NC}"
else
    echo -e "${RED}  ⚠️  Some tests failed. Check the output above.${NC}"
    echo -e "${YELLOW}     Tip: run 'sam logs -n StartMatchmaking --tail' to stream CloudWatch logs.${NC}"
fi

echo ""
