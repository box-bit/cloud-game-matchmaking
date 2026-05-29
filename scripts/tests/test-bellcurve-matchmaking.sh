#!/bin/bash
# =============================================================================
# test-bellcurve-matchmaking.sh
# Tests ELO tolerance expansion with a bell-curve player pool (spread 480).
#
# Timeline:
#   t=0s    Submit all 8 tickets
#   t~5s    Poller cycle 1 — tolerance ±200 — spread 480 > 200 → NO MATCH
#   t~65s   Poller cycle 2 — tolerance ±400 — spread 480 > 400 → NO MATCH
#   t~125s  Poller cycle 3 — tolerance ±800 — spread 480 < 800 → MATCH ✅
# =============================================================================
# Prerequisites:
#   - sam deploy has been run
#   - scripts/tests/setup-bellcurve-test.sh has been run
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

step()  { echo -e "\n${BLUE}▶ $1${NC}"; }
ok()    { echo -e "${GREEN}  ✅ $1${NC}"; }
warn()  { echo -e "${YELLOW}  ⚠ $1${NC}"; }
info()  { echo "     $1"; }
hr()    { echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"; }

# Countdown to a target epoch second, printing remaining seconds each second.
# Usage: countdown_to TARGET_EPOCH LABEL
countdown_to() {
    local TARGET="$1"
    local LABEL="$2"
    while true; do
        local NOW
        NOW=$(date +%s)
        local REMAINING=$(( TARGET - NOW ))
        [ "$REMAINING" -le 0 ] && break
        printf "\r     ⏳ %s in %3ds..." "$LABEL" "$REMAINING"
        sleep 1
    done
    printf "\r                                          \r"
}

# ── Pre-flight ────────────────────────────────────────────────────────────────
step "Pre-flight checks"

if [ ! -f ".session/bellcurve/players.tsv" ]; then
    echo -e "${RED}  ❌ .session/bellcurve/players.tsv not found.${NC}"
    echo "     Run scripts/tests/setup-bellcurve-test.sh first."
    exit 1
fi

if [ ! -f ".session/api_url.txt" ] || [ -z "$(cat .session/api_url.txt)" ]; then
    echo -e "${RED}  ❌ .session/api_url.txt missing. Run scripts/get-token.sh first.${NC}"
    exit 1
fi

API_URL=$(cat .session/api_url.txt)
CLIENT_ID=$(aws cloudformation describe-stacks \
    --stack-name matchmaking-engine \
    --query "Stacks[0].Outputs[?OutputKey=='UserPoolClientId'].OutputValue" \
    --output text)

ok "API URL: $API_URL"

# ── Load player data ──────────────────────────────────────────────────────────
step "Loading bell-curve player profiles"

declare -a EMAILS PASSWORDS SUBS ELOS
NUM_PLAYERS=0

while IFS=$'\t' read -r num email password sub elo; do
    EMAILS[$num]="$email"
    PASSWORDS[$num]="$password"
    SUBS[$num]="$sub"
    ELOS[$num]="$elo"
    NUM_PLAYERS=$num
done < .session/bellcurve/players.tsv

ELO_MIN="${ELOS[1]}"
ELO_MAX="${ELOS[$NUM_PLAYERS]}"
ELO_SPREAD=$(( ELO_MAX - ELO_MIN ))

info "Loaded $NUM_PLAYERS players  ELO range: $ELO_MIN–$ELO_MAX  spread: $ELO_SPREAD"
info "Expected: NO match at ±200 (t<60s) and ±400 (t<120s), MATCH at ±800 (t≥120s)"

# ── Authenticate all players ──────────────────────────────────────────────────
step "Authenticating $NUM_PLAYERS players"

declare -a TOKENS

for i in $(seq 1 $NUM_PLAYERS); do
    AUTH=$(aws cognito-idp initiate-auth \
        --auth-flow USER_PASSWORD_AUTH \
        --client-id "$CLIENT_ID" \
        --auth-parameters USERNAME="${EMAILS[$i]}",PASSWORD="${PASSWORDS[$i]}" \
        2>/dev/null)

    TOKENS[$i]=$(echo "$AUTH" | python3 -c \
        "import sys,json; print(json.load(sys.stdin)['AuthenticationResult']['IdToken'])")

    if [ -n "${TOKENS[$i]}" ]; then
        echo -e "  Player $i (${EMAILS[$i]})  ELO ${ELOS[$i]}  ${GREEN}✅${NC}"
    else
        echo -e "  Player $i  ${RED}❌ auth failed — aborting${NC}"
        exit 1
    fi
done

# ── Check for stale SEARCHING tickets ─────────────────────────────────────────
step "Checking for stale tickets"

STALE=$(aws dynamodb scan \
    --table-name MatchmakingTickets \
    --filter-expression "#s = :v" \
    --expression-attribute-names '{"#s":"Status"}' \
    --expression-attribute-values '{":v":{"S":"SEARCHING"}}' \
    --select COUNT \
    --query "Count" \
    --output text 2>/dev/null || echo 0)

if [ "$STALE" -gt 0 ]; then
    warn "$STALE existing SEARCHING ticket(s) found — may interfere with results."
else
    ok "No stale SEARCHING tickets."
fi

# ── Submit matchmaking tickets ────────────────────────────────────────────────
step "Submitting matchmaking tickets for all $NUM_PLAYERS players"

declare -a TICKET_IDS FINAL_STATUSES MATCH_TIMES SERVER_IPS SERVER_PORTS
SUBMIT_OK=0

TEST_START=$(date +%s)
mkdir -p /tmp/bellcurve-test

for i in $(seq 1 $NUM_PLAYERS); do
    RESP=$(curl -s -w "\n%{http_code}" -X POST "$API_URL/match" \
        -H "Authorization: Bearer ${TOKENS[$i]}")
    HTTP_CODE=$(echo "$RESP" | tail -n1)
    BODY=$(echo "$RESP" | head -n1)

    TICKET_IDS[$i]=$(echo "$BODY" | python3 -c \
        "import sys,json; print(json.load(sys.stdin).get('ticketId',''))" 2>/dev/null || echo "")
    FINAL_STATUSES[$i]="SEARCHING"

    if [ "$HTTP_CODE" = "200" ] && [ -n "${TICKET_IDS[$i]}" ]; then
        echo -e "  Player $i  ELO ${ELOS[$i]}  ${GREEN}✅${NC}  ticket=${TICKET_IDS[$i]:0:12}..."
        SUBMIT_OK=$((SUBMIT_OK + 1))
    else
        echo -e "  Player $i  ${RED}❌${NC}  HTTP $HTTP_CODE  $BODY"
        FINAL_STATUSES[$i]="SUBMIT_FAILED"
    fi
done

SUBMIT_TIME=$(( $(date +%s) - TEST_START ))
info ""
info "$SUBMIT_OK / $NUM_PLAYERS tickets submitted in ${SUBMIT_TIME}s."

# ── Poller cycle 1 — tolerance ±200 — expect NO MATCH ─────────────────────────
step "Poller cycle 1 — t≈${SUBMIT_TIME}s — tolerance ±200 — expect NO MATCH"

CYCLE1_T=$(( $(date +%s) - TEST_START ))
aws lambda invoke \
    --function-name MatchStatusPoller \
    --payload '{}' \
    /tmp/bellcurve-test/poller-cycle1.json > /dev/null

CYCLE1_RESP=$(cat /tmp/bellcurve-test/poller-cycle1.json)
info "Lambda response: $CYCLE1_RESP"

# Count statuses right after cycle 1
CYCLE1_SEARCHING=0
set +e
for i in $(seq 1 $NUM_PLAYERS); do
    [ -z "${TICKET_IDS[$i]}" ] && continue
    STATUS=$(curl -s "$API_URL/match/${TICKET_IDS[$i]}" \
        -H "Authorization: Bearer ${TOKENS[$i]}" 2>/dev/null | \
        python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "SEARCHING")
    [ "$STATUS" = "SEARCHING" ] && CYCLE1_SEARCHING=$(( CYCLE1_SEARCHING + 1 ))
done
set -e

if [ "$CYCLE1_SEARCHING" -eq "$NUM_PLAYERS" ]; then
    ok "Cycle 1: all $NUM_PLAYERS still SEARCHING — tolerance too tight ✅ (expected)"
else
    warn "Cycle 1: $(( NUM_PLAYERS - CYCLE1_SEARCHING )) player(s) already matched (unexpected)"
fi

# ── Wait for t=65s since ticket submission ────────────────────────────────────
TARGET_CYCLE2=$(( TEST_START + 65 ))
NOW=$(date +%s)
if [ "$NOW" -lt "$TARGET_CYCLE2" ]; then
    echo ""
    info "Waiting for tickets to age past 60s (tolerance expands to ±400)..."
    countdown_to "$TARGET_CYCLE2" "Cycle 2"
fi

# ── Poller cycle 2 — tolerance ±400 — expect NO MATCH ─────────────────────────
CYCLE2_T=$(( $(date +%s) - TEST_START ))
step "Poller cycle 2 — t≈${CYCLE2_T}s — tolerance ±400 — expect NO MATCH"

aws lambda invoke \
    --function-name MatchStatusPoller \
    --payload '{}' \
    /tmp/bellcurve-test/poller-cycle2.json > /dev/null

CYCLE2_RESP=$(cat /tmp/bellcurve-test/poller-cycle2.json)
info "Lambda response: $CYCLE2_RESP"

CYCLE2_SEARCHING=0
set +e
for i in $(seq 1 $NUM_PLAYERS); do
    [ -z "${TICKET_IDS[$i]}" ] && continue
    STATUS=$(curl -s "$API_URL/match/${TICKET_IDS[$i]}" \
        -H "Authorization: Bearer ${TOKENS[$i]}" 2>/dev/null | \
        python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "SEARCHING")
    [ "$STATUS" = "SEARCHING" ] && CYCLE2_SEARCHING=$(( CYCLE2_SEARCHING + 1 ))
done
set -e

if [ "$CYCLE2_SEARCHING" -eq "$NUM_PLAYERS" ]; then
    ok "Cycle 2: all $NUM_PLAYERS still SEARCHING — tolerance too tight ✅ (expected)"
else
    warn "Cycle 2: $(( NUM_PLAYERS - CYCLE2_SEARCHING )) player(s) matched (unexpected)"
fi

# ── Wait for t=125s since ticket submission ───────────────────────────────────
TARGET_CYCLE3=$(( TEST_START + 125 ))
NOW=$(date +%s)
if [ "$NOW" -lt "$TARGET_CYCLE3" ]; then
    echo ""
    info "Waiting for tickets to age past 120s (tolerance expands to ±800)..."
    countdown_to "$TARGET_CYCLE3" "Cycle 3"
fi

# ── Poller cycle 3 — tolerance ±800 — expect MATCH ────────────────────────────
CYCLE3_T=$(( $(date +%s) - TEST_START ))
step "Poller cycle 3 — t≈${CYCLE3_T}s — tolerance ±800 — expect MATCH ✅"

aws lambda invoke \
    --function-name MatchStatusPoller \
    --payload '{}' \
    /tmp/bellcurve-test/poller-cycle3.json > /dev/null

CYCLE3_RESP=$(cat /tmp/bellcurve-test/poller-cycle3.json)
info "Lambda response: $CYCLE3_RESP"

# ── Poll for terminal statuses ────────────────────────────────────────────────
step "Polling ticket statuses (up to 30s)"

MAX_ROUNDS=15
POLL_INTERVAL=2

set +e

for round in $(seq 1 $MAX_ROUNDS); do
    PENDING=0

    for i in $(seq 1 $NUM_PLAYERS); do
        [ "${FINAL_STATUSES[$i]}" != "SEARCHING" ] && continue
        [ -z "${TICKET_IDS[$i]}" ] && continue

        RESP=$(curl -s "$API_URL/match/${TICKET_IDS[$i]}" \
            -H "Authorization: Bearer ${TOKENS[$i]}" 2>/dev/null)

        STATUS=$(echo "$RESP" | python3 -c \
            "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "SEARCHING")

        if [ "$STATUS" != "SEARCHING" ]; then
            FINAL_STATUSES[$i]="$STATUS"
            MATCH_TIMES[$i]=$(( $(date +%s) - TEST_START ))
            SERVER_IPS[$i]=$(echo "$RESP" | python3 -c \
                "import sys,json; print(json.load(sys.stdin).get('serverIp',''))" 2>/dev/null || echo "")
            SERVER_PORTS[$i]=$(echo "$RESP" | python3 -c \
                "import sys,json; print(json.load(sys.stdin).get('serverPort',''))" 2>/dev/null || echo "")
        else
            PENDING=$(( PENDING + 1 ))
        fi
    done

    echo "  Round $round: $PENDING still SEARCHING"
    [ "$PENDING" -eq 0 ] && break
    sleep $POLL_INTERVAL
done

set -e

# ── Report ────────────────────────────────────────────────────────────────────
echo ""
hr
echo -e "${BOLD}  BELL-CURVE ELO MATCHMAKING TEST REPORT${NC}"
echo -e "  $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
hr

SUCCEEDED=0
TIMED_OUT=0
OTHER=0
TOTAL_TIME=0
TIME_COUNT=0

for i in $(seq 1 $NUM_PLAYERS); do
    case "${FINAL_STATUSES[$i]}" in
        SUCCEEDED)
            SUCCEEDED=$(( SUCCEEDED + 1 ))
            if [ -n "${MATCH_TIMES[$i]}" ]; then
                TOTAL_TIME=$(( TOTAL_TIME + MATCH_TIMES[$i] ))
                TIME_COUNT=$(( TIME_COUNT + 1 ))
            fi
            ;;
        TIMED_OUT) TIMED_OUT=$(( TIMED_OUT + 1 )) ;;
        *)         OTHER=$(( OTHER + 1 )) ;;
    esac
done

AVG_TIME=0
[ "$TIME_COUNT" -gt 0 ] && AVG_TIME=$(( TOTAL_TIME / TIME_COUNT ))

# Count unique server endpoints
declare -A SERVERS
for i in $(seq 1 $NUM_PLAYERS); do
    if [ -n "${SERVER_IPS[$i]}" ] && [ -n "${SERVER_PORTS[$i]}" ]; then
        SERVERS["${SERVER_IPS[$i]}:${SERVER_PORTS[$i]}"]=1
    fi
done
UNIQUE_SERVERS=${#SERVERS[@]}

echo ""
if [ "$SUCCEEDED" -eq "$NUM_PLAYERS" ]; then
    echo -e "  ${GREEN}${BOLD}RESULT: ALL $NUM_PLAYERS PLAYERS MATCHED ✅${NC}"
elif [ "$SUCCEEDED" -gt 0 ]; then
    echo -e "  ${YELLOW}${BOLD}RESULT: PARTIAL — $SUCCEEDED / $NUM_PLAYERS matched${NC}"
else
    echo -e "  ${RED}${BOLD}RESULT: FAILED — 0 / $NUM_PLAYERS matched${NC}"
fi

echo ""
printf "  %-26s %s\n"  "ELO distribution:"     "${ELOS[1]}–${ELOS[$NUM_PLAYERS]} (spread ${ELO_SPREAD})"
printf "  %-26s %s\n"  "Players matched:"       "$SUCCEEDED / $NUM_PLAYERS"
[ "$TIMED_OUT" -gt 0 ] && printf "  %-26s %s\n" "Timed out:"   "$TIMED_OUT"
[ "$OTHER"     -gt 0 ] && printf "  %-26s %s\n" "Other:"       "$OTHER"
printf "  %-26s %ss\n" "Avg time to match:"     "$AVG_TIME"
printf "  %-26s %s\n"  "Servers used:"          "$UNIQUE_SERVERS"

echo ""
echo -e "  ${BOLD}Tolerance window timeline:${NC}"
printf "  %-10s %-10s %-10s %s\n" "Cycle" "t (s)" "Tolerance" "Outcome"
echo "  ──────────────────────────────────────────"
printf "  %-10s %-10s %-10s %s\n" "1" "${CYCLE1_T}s" "±200" "$([ "$CYCLE1_SEARCHING" -eq "$NUM_PLAYERS" ] && echo "NO MATCH (expected)" || echo "MATCHED (unexpected)")"
printf "  %-10s %-10s %-10s %s\n" "2" "${CYCLE2_T}s" "±400" "$([ "$CYCLE2_SEARCHING" -eq "$NUM_PLAYERS" ] && echo "NO MATCH (expected)" || echo "MATCHED (unexpected)")"
printf "  %-10s %-10s %-10s %s\n" "3" "${CYCLE3_T}s" "±800" "$([ "$SUCCEEDED" -gt 0 ] && echo "MATCH ✅" || echo "NO MATCH ❌")"
echo "  ──────────────────────────────────────────"

# Unique server summary
if [ "$UNIQUE_SERVERS" -gt 0 ]; then
    echo ""
    echo -e "  ${BOLD}Server(s) allocated:${NC}"
    for server in "${!SERVERS[@]}"; do
        MEMBERS=""
        for i in $(seq 1 $NUM_PLAYERS); do
            KEY="${SERVER_IPS[$i]}:${SERVER_PORTS[$i]}"
            [ "$KEY" = "$server" ] && MEMBERS="$MEMBERS P$i(ELO ${ELOS[$i]})"
        done
        echo -e "  ${CYAN}$server${NC}  →  $MEMBERS"
    done
fi

# Per-player detail table
echo ""
echo -e "  ${BOLD}Per-player detail:${NC}"
echo "  ───────────────────────────────────────────────────────────────────────"
printf "  %-8s %-6s %-16s %-14s %-6s %s\n" \
    "Player" "ELO" "Ticket (prefix)" "Status" "Time" "Server"
echo "  ───────────────────────────────────────────────────────────────────────"

for i in $(seq 1 $NUM_PLAYERS); do
    TICKET_DISP="${TICKET_IDS[$i]:0:12}..."
    [ -z "${TICKET_IDS[$i]}" ] && TICKET_DISP="—"

    TIME_DISP="${MATCH_TIMES[$i]}s"
    [ -z "${MATCH_TIMES[$i]}" ] && TIME_DISP="—"

    SERVER_DISP="${SERVER_IPS[$i]}:${SERVER_PORTS[$i]}"
    [ -z "${SERVER_IPS[$i]}" ] && SERVER_DISP="—"

    case "${FINAL_STATUSES[$i]}" in
        SUCCEEDED)     STATUS_CLR="${GREEN}SUCCEEDED    ${NC}" ;;
        TIMED_OUT)     STATUS_CLR="${YELLOW}TIMED_OUT    ${NC}" ;;
        SUBMIT_FAILED) STATUS_CLR="${RED}SUBMIT_FAIL  ${NC}" ;;
        SEARCHING)     STATUS_CLR="${YELLOW}SEARCHING    ${NC}" ;;
        *)             STATUS_CLR="${RED}${FINAL_STATUSES[$i]}${NC}" ;;
    esac

    printf "  %-8s %-6s %-16s " "$i" "${ELOS[$i]}" "$TICKET_DISP"
    echo -e "${STATUS_CLR}  ${TIME_DISP}   ${SERVER_DISP}"
done

echo "  ───────────────────────────────────────────────────────────────────────"
echo ""
echo -e "  ${BOLD}Comparison (bell curve vs tight ELO):${NC}"
printf "  %-28s %s\n" "Tight ELO (spread ~70):"    "matched at cycle 1 — ~60s total"
printf "  %-28s %ss total\n" "Bell curve (spread $ELO_SPREAD):" "$AVG_TIME"
echo ""
hr

if [ "$SUCCEEDED" -eq "$NUM_PLAYERS" ]; then
    echo -e "${GREEN}  Test PASSED.${NC}"
    EXIT_CODE=0
else
    echo -e "${RED}  Test FAILED.${NC}"
    echo -e "${YELLOW}  Debug:  sam logs -n MatchStatusPoller --tail${NC}"
    EXIT_CODE=1
fi

echo ""
exit $EXIT_CODE
