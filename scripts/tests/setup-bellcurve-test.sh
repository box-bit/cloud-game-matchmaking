#!/bin/bash
# =============================================================================
# setup-bellcurve-test.sh
# Creates 8 Cognito test players whose ELOs follow a bell curve distribution
# (spread 480 ELO, mean ~1290). Safe to run multiple times — skips players
# already present in DynamoDB.
# =============================================================================
# ELO distribution:
#
#          *   *
#        *       *
#      *           *
#    *               *
#  1050 1150 1200 1270 1330 1390 1450 1530
#
# Spread 480 ELO — exceeds the ±200 and ±400 matchmaking windows,
# so the group only forms after the tolerance widens to ±800 (after 120 s).
# =============================================================================
# Run once after deploy, then run the test anytime with:
#   ./scripts/tests/test-bellcurve-matchmaking.sh
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

step() { echo -e "\n${BLUE}▶ $1${NC}"; }
ok()   { echo -e "${GREEN}  ✅ $1${NC}"; }
info() { echo "     $1"; }

EMAILS=(
    "match-bell-1@example.com"
    "match-bell-2@example.com"
    "match-bell-3@example.com"
    "match-bell-4@example.com"
    "match-bell-5@example.com"
    "match-bell-6@example.com"
    "match-bell-7@example.com"
    "match-bell-8@example.com"
)
# Bell curve: tails at 1050 and 1530, peak around 1270–1330
ELOS=(1050 1150 1200 1270 1330 1390 1450 1530)
PASSWORD="MatchTest123"
NUM_PLAYERS=${#EMAILS[@]}

# ── CloudFormation outputs ─────────────────────────────────────────────────────
step "Fetching CloudFormation outputs"

USER_POOL_ID=$(aws cloudformation describe-stacks \
    --stack-name matchmaking-engine \
    --query "Stacks[0].Outputs[?OutputKey=='UserPoolId'].OutputValue" \
    --output text)

CLIENT_ID=$(aws cloudformation describe-stacks \
    --stack-name matchmaking-engine \
    --query "Stacks[0].Outputs[?OutputKey=='UserPoolClientId'].OutputValue" \
    --output text)

info "User Pool ID : $USER_POOL_ID"
info "Client ID    : $CLIENT_ID"

# ── Create & seed players ──────────────────────────────────────────────────────
step "Checking and creating $NUM_PLAYERS test players"

mkdir -p .session/bellcurve
: > .session/bellcurve/players.tsv

CREATED=0
SKIPPED=0

for i in $(seq 0 $((NUM_PLAYERS - 1))); do
    EMAIL="${EMAILS[$i]}"
    ELO="${ELOS[$i]}"
    PLAYER_NUM=$((i + 1))

    printf "  Player %-2d  %-32s ELO %-4d  " "$PLAYER_NUM" "$EMAIL" "$ELO"

    SUB=$(aws cognito-idp admin-get-user \
        --user-pool-id "$USER_POOL_ID" \
        --username "$EMAIL" \
        --query "UserAttributes[?Name=='sub'].Value" \
        --output text 2>/dev/null || echo "")

    if [ -n "$SUB" ] && [ "$SUB" != "None" ]; then
        DB_CHECK=$(aws dynamodb get-item \
            --table-name PlayerProfiles \
            --key "{\"UserId\": {\"S\": \"$SUB\"}}" \
            --query "Item.ELO.N" \
            --output text 2>/dev/null || echo "")

        if [ -n "$DB_CHECK" ] && [ "$DB_CHECK" != "None" ]; then
            echo -e "${GREEN}already exists — skipped${NC}"
            printf "%d\t%s\t%s\t%s\t%d\n" \
                "$PLAYER_NUM" "$EMAIL" "$PASSWORD" "$SUB" "$ELO" \
                >> .session/bellcurve/players.tsv
            SKIPPED=$((SKIPPED + 1))
            continue
        fi

        echo -n "(Cognito ✓, seeding DynamoDB) "
    else
        echo -n "(creating) "

        CREATE=$(aws cognito-idp admin-create-user \
            --user-pool-id "$USER_POOL_ID" \
            --username "$EMAIL" \
            --user-attributes Name=email,Value="$EMAIL" Name=email_verified,Value=true \
            --message-action SUPPRESS) || {
            echo -e "${RED}❌ admin-create-user failed — aborting${NC}"
            exit 1
        }

        SUB=$(echo "$CREATE" | python3 -c \
            "import sys,json; attrs=json.load(sys.stdin)['User']['Attributes']; \
             print(next(a['Value'] for a in attrs if a['Name']=='sub'))")

        aws cognito-idp admin-set-user-password \
            --user-pool-id "$USER_POOL_ID" \
            --username "$EMAIL" \
            --password "$PASSWORD" \
            --permanent > /dev/null
    fi

    aws dynamodb put-item \
        --table-name PlayerProfiles \
        --item "{
            \"UserId\":   {\"S\": \"$SUB\"},
            \"Username\": {\"S\": \"match-bell-$PLAYER_NUM\"},
            \"ELO\":      {\"N\": \"$ELO\"},
            \"Wins\":     {\"N\": \"5\"},
            \"Losses\":   {\"N\": \"3\"}
        }" > /dev/null

    printf "%d\t%s\t%s\t%s\t%d\n" \
        "$PLAYER_NUM" "$EMAIL" "$PASSWORD" "$SUB" "$ELO" \
        >> .session/bellcurve/players.tsv

    echo -e "${GREEN}✅ created${NC}"
    CREATED=$((CREATED + 1))
done

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Setup complete — $NUM_PLAYERS players ready.${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo ""
info "Created : $CREATED   Skipped (already in DynamoDB): $SKIPPED"
info "ELO distribution : ${ELOS[0]}–${ELOS[$((NUM_PLAYERS-1))]}  (spread $((ELOS[$((NUM_PLAYERS-1))] - ELOS[0])) ELO)"
info "Matchmaking windows:"
info "  ±200 (0–60s)   — spread 480 > 200 — NO match"
info "  ±400 (60–120s) — spread 480 > 400 — NO match"
info "  ±800 (120s+)   — spread 480 < 800 — MATCH"
info ""
info "Player data saved to .session/bellcurve/players.tsv"
echo ""
echo -e "  Run the test:  ${YELLOW}./scripts/tests/test-bellcurve-matchmaking.sh${NC}"
echo ""
