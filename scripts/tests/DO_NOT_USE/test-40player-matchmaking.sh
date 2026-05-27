#!/bin/bash
# =============================================================================
# test-40player-matchmaking.sh
# Authenticates 40 test players, submits their matchmaking tickets in parallel,
# invokes the MatchStatusPoller (up to 3 times to allow ECS task start-up),
# polls until all 40 reach a terminal status, then prints a full report.
# =============================================================================
# Prerequisites:
#   - sam deploy has been run
#   - scripts/tests/setup-40player-test.sh has been run
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

TMPDIR=/tmp/40p-test
mkdir -p "$TMPDIR"

# ── Pre-flight ────────────────────────────────────────────────────────────────
step "Pre-flight checks"

if [ ! -f ".session/40player/players.tsv" ]; then
    echo -e "${RED}  ❌ .session/40player/players.tsv not found.${NC}"
    echo "     Run scripts/tests/setup-40player-test.sh first."
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
step "Loading player profiles"

declare -a EMAILS PASSWORDS SUBS ELOS
NUM_PLAYERS=0

while IFS=$'\t' read -r num email password sub elo; do
    EMAILS[$num]="$email"
    PASSWORDS[$num]="$password"
    SUBS[$num]="$sub"
    ELOS[$num]="$elo"
    NUM_PLAYERS=$num
done < .session/40player/players.tsv

EXPECTED_GROUPS=$(( NUM_PLAYERS / 8 ))
info "Loaded $NUM_PLAYERS players  (ELO ${ELOS[1]}–${ELOS[$NUM_PLAYERS]}, $EXPECTED_GROUPS expected groups)"

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
        printf "  [%2d/%d] ${GREEN}✅${NC}  %s\n" "$i" "$NUM_PLAYERS" "${EMAILS[$i]}"
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
    warn "$STALE existing SEARCHING ticket(s) — may affect group formation order."
else
    ok "No stale SEARCHING tickets."
fi

# ── Submit all 40 tickets in parallel ────────────────────────────────────────
step "Submitting $NUM_PLAYERS matchmaking tickets in parallel"

declare -a TICKET_IDS FINAL_STATUSES MATCH_TIMES SERVER_IPS SERVER_PORTS
TEST_START=$(date +%s)

# Save tokens to files so background subshells can read them
for i in $(seq 1 $NUM_PLAYERS); do
    printf "%s" "${TOKENS[$i]}" > "$TMPDIR/token_$i.txt"
done

# Fire all POST /match calls simultaneously
for i in $(seq 1 $NUM_PLAYERS); do
    (
        TOKEN=$(cat "$TMPDIR/token_$i.txt")
        RESP=$(curl -s -w "\n%{http_code}" -X POST "$API_URL/match" \
            -H "Authorization: Bearer $TOKEN")
        printf "%s" "$RESP" > "$TMPDIR/submit_$i.txt"
    ) &
done
wait

# Collect results
SUBMIT_OK=0
for i in $(seq 1 $NUM_PLAYERS); do
    RESP=$(cat "$TMPDIR/submit_$i.txt" 2>/dev/null || echo "")
    HTTP_CODE=$(echo "$RESP" | tail -n1)
    BODY=$(echo "$RESP" | head -n1)

    TICKET_IDS[$i]=$(echo "$BODY" | python3 -c \
        "import sys,json; print(json.load(sys.stdin).get('ticketId',''))" 2>/dev/null || echo "")

    if [ "$HTTP_CODE" = "200" ] && [ -n "${TICKET_IDS[$i]}" ]; then
        FINAL_STATUSES[$i]="SEARCHING"
        SUBMIT_OK=$((SUBMIT_OK + 1))
    else
        FINAL_STATUSES[$i]="SUBMIT_FAILED"
    fi
done

info "$SUBMIT_OK / $NUM_PLAYERS tickets submitted successfully."
[ "$SUBMIT_OK" -lt "$NUM_PLAYERS" ] && warn "$(( NUM_PLAYERS - SUBMIT_OK )) submission(s) failed."

# ── Lambda invocation + polling loop ─────────────────────────────────────────
# The warm pool keeps 2 ECS tasks ready. With 5 groups needed, the first Lambda
# run uses those 2 then starts new tasks (each ~10–20 s). If it times out before
# finishing all groups the remaining tickets stay SEARCHING — a second or third
# invocation picks them up.
# ─────────────────────────────────────────────────────────────────────────────

MAX_LAMBDA_INVOCATIONS=4
POLL_ROUNDS_PER_INVOKE=10
POLL_INTERVAL=3

for invoke_num in $(seq 1 $MAX_LAMBDA_INVOCATIONS); do

    # Check whether any tickets are still SEARCHING
    STILL_SEARCHING=0
    for i in $(seq 1 $NUM_PLAYERS); do
        [ "${FINAL_STATUSES[$i]}" = "SEARCHING" ] && STILL_SEARCHING=$((STILL_SEARCHING + 1))
    done
    [ "$STILL_SEARCHING" -eq 0 ] && break

    step "Lambda invocation $invoke_num / $MAX_LAMBDA_INVOCATIONS  ($STILL_SEARCHING tickets still searching)"

    aws lambda invoke \
        --function-name MatchStatusPoller \
        --payload '{}' \
        "$TMPDIR/poller-$invoke_num.json" > /dev/null

    POLLER_RESP=$(cat "$TMPDIR/poller-$invoke_num.json")
    info "Lambda response: $POLLER_RESP"

    # Poll in parallel until all pending tickets resolve or we exhaust rounds
    set +e

    for round in $(seq 1 $POLL_ROUNDS_PER_INVOKE); do
        PENDING=0

        # Fire all pending polls simultaneously
        for i in $(seq 1 $NUM_PLAYERS); do
            [ "${FINAL_STATUSES[$i]}" != "SEARCHING" ] && continue
            [ -z "${TICKET_IDS[$i]}" ] && continue
            PENDING=$((PENDING + 1))
            (
                TOKEN=$(cat "$TMPDIR/token_$i.txt")
                RESP=$(curl -s "$API_URL/match/${TICKET_IDS[$i]}" \
                    -H "Authorization: Bearer $TOKEN" 2>/dev/null)
                printf "%s" "$RESP" > "$TMPDIR/poll_${i}.txt"
            ) &
        done
        wait

        # Read poll results back
        NEWLY_RESOLVED=0
        for i in $(seq 1 $NUM_PLAYERS); do
            [ "${FINAL_STATUSES[$i]}" != "SEARCHING" ] && continue
            [ -z "${TICKET_IDS[$i]}" ] && continue

            RESP=$(cat "$TMPDIR/poll_${i}.txt" 2>/dev/null || echo "{}")
            STATUS=$(echo "$RESP" | python3 -c \
                "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")

            [ -z "$STATUS" ] && continue

            if [ "$STATUS" != "SEARCHING" ]; then
                FINAL_STATUSES[$i]="$STATUS"
                MATCH_TIMES[$i]=$(( $(date +%s) - TEST_START ))
                SERVER_IPS[$i]=$(echo "$RESP" | python3 -c \
                    "import sys,json; print(json.load(sys.stdin).get('serverIp',''))" 2>/dev/null || echo "")
                SERVER_PORTS[$i]=$(echo "$RESP" | python3 -c \
                    "import sys,json; print(json.load(sys.stdin).get('serverPort',''))" 2>/dev/null || echo "")
                PENDING=$((PENDING - 1))
                NEWLY_RESOLVED=$((NEWLY_RESOLVED + 1))
            fi
        done

        echo "  Round $round: $PENDING still SEARCHING  (+$NEWLY_RESOLVED resolved this round)"
        [ "$PENDING" -eq 0 ] && break
        sleep $POLL_INTERVAL
    done

    set -e

    # Brief gap before the next Lambda invocation so ECS tasks have time to start
    [ "$invoke_num" -lt "$MAX_LAMBDA_INVOCATIONS" ] && [ "$PENDING" -gt 0 ] && sleep 5

done

# ── Build report ──────────────────────────────────────────────────────────────
echo ""
hr
echo -e "${BOLD}  40-PLAYER MATCHMAKING TEST REPORT${NC}"
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
            SUCCEEDED=$((SUCCEEDED + 1))
            if [ -n "${MATCH_TIMES[$i]}" ]; then
                TOTAL_TIME=$((TOTAL_TIME + MATCH_TIMES[$i]))
                TIME_COUNT=$((TIME_COUNT + 1))
            fi
            ;;
        TIMED_OUT)     TIMED_OUT=$((TIMED_OUT + 1)) ;;
        *)             OTHER=$((OTHER + 1)) ;;
    esac
done

AVG_TIME=0
[ "$TIME_COUNT" -gt 0 ] && AVG_TIME=$(( TOTAL_TIME / TIME_COUNT ))

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
printf "  %-20s %s\n"  "Players matched:"    "$SUCCEEDED / $NUM_PLAYERS"
printf "  %-20s %s\n"  "Expected groups:"    "$EXPECTED_GROUPS (8 players each)"
printf "  %-20s %s\n"  "Groups formed:"      "$UNIQUE_SERVERS"
[ "$TIMED_OUT" -gt 0 ] && printf "  %-20s %s\n" "Timed out:"      "$TIMED_OUT"
[ "$OTHER"     -gt 0 ] && printf "  %-20s %s\n" "Other failures:" "$OTHER"
printf "  %-20s %ss\n" "Avg time to match:"  "$AVG_TIME"
printf "  %-20s %s\n"  "Lambda invocations:" "$invoke_num"

# ── Group summary ─────────────────────────────────────────────────────────────
if [ "$UNIQUE_SERVERS" -gt 0 ]; then
    echo ""
    echo -e "  ${BOLD}Groups:${NC}"
    GROUP_NUM=1
    for server in "${!SERVERS[@]}"; do
        MEMBERS=""
        ELO_LIST=()
        for i in $(seq 1 $NUM_PLAYERS); do
            KEY="${SERVER_IPS[$i]}:${SERVER_PORTS[$i]}"
            if [ "$KEY" = "$server" ]; then
                MEMBERS="$MEMBERS P$i"
                ELO_LIST+=("${ELOS[$i]}")
            fi
        done
        COUNT=$(echo "$MEMBERS" | wc -w)
        MIN_ELO="${ELO_LIST[0]}"
        MAX_ELO="${ELO_LIST[0]}"
        for e in "${ELO_LIST[@]}"; do
            [ "$e" -lt "$MIN_ELO" ] && MIN_ELO="$e"
            [ "$e" -gt "$MAX_ELO" ] && MAX_ELO="$e"
        done
        echo -e "  Group $GROUP_NUM  ${CYAN}$server${NC}  players=$COUNT  ELO ${MIN_ELO}–${MAX_ELO}  [$MEMBERS ]"
        GROUP_NUM=$((GROUP_NUM + 1))
    done
fi

# ── Per-player table ──────────────────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}Per-player detail:${NC}"
echo "  ────────────────────────────────────────────────────────────────────"
printf "  %-6s %-6s %-14s %-12s %-5s %s\n" \
    "Player" "ELO" "Ticket" "Status" "Time" "Server"
echo "  ────────────────────────────────────────────────────────────────────"

for i in $(seq 1 $NUM_PLAYERS); do
    TICKET_DISP="${TICKET_IDS[$i]:0:10}..."
    [ -z "${TICKET_IDS[$i]}" ] && TICKET_DISP="—"

    TIME_DISP="${MATCH_TIMES[$i]}s"
    [ -z "${MATCH_TIMES[$i]}" ] && TIME_DISP="—"

    SERVER_DISP="${SERVER_IPS[$i]}:${SERVER_PORTS[$i]}"
    [ -z "${SERVER_IPS[$i]}" ] && SERVER_DISP="—"

    case "${FINAL_STATUSES[$i]}" in
        SUCCEEDED)     S="${GREEN}SUCCEEDED  ${NC}" ;;
        TIMED_OUT)     S="${YELLOW}TIMED_OUT  ${NC}" ;;
        SUBMIT_FAILED) S="${RED}SUBMIT_FAIL${NC}" ;;
        SEARCHING)     S="${YELLOW}SEARCHING  ${NC}" ;;
        *)             S="${RED}${FINAL_STATUSES[$i]}${NC}" ;;
    esac

    printf "  %-6s %-6s %-14s " "$i" "${ELOS[$i]}" "$TICKET_DISP"
    echo -e "${S}  ${TIME_DISP}  ${SERVER_DISP}"
done

echo "  ────────────────────────────────────────────────────────────────────"
echo ""
hr

if [ "$SUCCEEDED" -eq "$NUM_PLAYERS" ]; then
    echo -e "${GREEN}  Test PASSED.${NC}"
    EXIT_CODE=0
else
    echo -e "${RED}  Test FAILED — $((NUM_PLAYERS - SUCCEEDED)) player(s) unmatched.${NC}"
    echo -e "${YELLOW}  Debug: sam logs -n MatchStatusPoller --tail${NC}"
    EXIT_CODE=1
fi

echo ""
exit $EXIT_CODE
