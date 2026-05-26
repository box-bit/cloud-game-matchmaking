#!/bin/bash
# =============================================================================
# setup-40player-test.sh
# Creates 40 Cognito test players (match-40-{1..40}@example.com) with ELOs
# 1200–1590 and seeds their DynamoDB profiles. Skips any player already present
# in DynamoDB — only creates the missing ones. Safe to run multiple times.
# =============================================================================
# Run once after deploy, then run the test anytime with:
#   ./scripts/tests/test-40player-matchmaking.sh
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

NUM_PLAYERS=40
BASE_ELO=1200
ELO_STEP=10
PASSWORD="MatchTest123"

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

mkdir -p .session/40player
: > .session/40player/players.tsv   # clear / rebuild from fresh state

CREATED=0
SKIPPED=0

for n in $(seq 1 $NUM_PLAYERS); do
    EMAIL="match-40-$n@example.com"
    ELO=$((BASE_ELO + (n - 1) * ELO_STEP))

    printf "  [%2d/%d] %-32s ELO %-4d  " "$n" "$NUM_PLAYERS" "$EMAIL" "$ELO"

    # ── Fast path: check if Cognito user and DynamoDB profile both exist ──────
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
                "$n" "$EMAIL" "$PASSWORD" "$SUB" "$ELO" \
                >> .session/40player/players.tsv
            SKIPPED=$((SKIPPED + 1))
            continue
        fi

        # Cognito user exists but DynamoDB profile is missing — seed only
        echo -n "(Cognito ✓, seeding DynamoDB) "
    else
        # New player — use admin API (no verification email sent, avoids quota)
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

    # ── Seed DynamoDB profile ─────────────────────────────────────────────────
    aws dynamodb put-item \
        --table-name PlayerProfiles \
        --item "{
            \"UserId\":   {\"S\": \"$SUB\"},
            \"Username\": {\"S\": \"match-40-$n\"},
            \"ELO\":      {\"N\": \"$ELO\"},
            \"Wins\":     {\"N\": \"5\"},
            \"Losses\":   {\"N\": \"3\"}
        }" > /dev/null

    printf "%d\t%s\t%s\t%s\t%d\n" \
        "$n" "$EMAIL" "$PASSWORD" "$SUB" "$ELO" \
        >> .session/40player/players.tsv

    echo -e "${GREEN}✅ created${NC}"
    CREATED=$((CREATED + 1))
done

# ── Summary ────────────────────────────────────────────────────────────────────
LAST_ELO=$((BASE_ELO + (NUM_PLAYERS - 1) * ELO_STEP))
EXPECTED_GROUPS=$((NUM_PLAYERS / 8))

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Setup complete — $NUM_PLAYERS players ready.${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo ""
info "Created : $CREATED   Skipped (already in DynamoDB): $SKIPPED"
info "ELO spread      : ${BASE_ELO}–${LAST_ELO}  (step ${ELO_STEP}, max group spread 70)"
info "Match window    : ±200 ELO → every group of 8 fits on first attempt"
info "Expected groups : $EXPECTED_GROUPS  (${NUM_PLAYERS} players ÷ 8 per group)"
info ""
info "Player data saved to .session/40player/players.tsv"
echo ""
echo -e "  Run the test:  ${YELLOW}./scripts/tests/test-40player-matchmaking.sh${NC}"
echo ""
