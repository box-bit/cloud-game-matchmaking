#!/bin/bash
set -e

if [ ! -f ".session/sub.txt" ]; then
    echo "No sub found. Run scripts/get-token.sh first."
    exit 1
fi

SUB=$(cat .session/sub.txt)
echo "Seeding DynamoDB with UserId: $SUB"

aws dynamodb put-item \
    --table-name PlayerProfiles \
    --item "{
    \"UserId\":   {\"S\": \"$SUB\"},
    \"Username\": {\"S\": \"testplayer\"},
    \"ELO\":      {\"N\": \"1200\"},
    \"Wins\":     {\"N\": \"10\"},
    \"Losses\":   {\"N\": \"5\"}
  }"

# Second test player with a fixed ID — useful for simulating an opponent
aws dynamodb put-item \
    --table-name PlayerProfiles \
    --item '{
    "UserId":   {"S": "test-opponent-001"},
    "Username": {"S": "test-opponent"},
    "ELO":      {"N": "1350"},
    "Wins":     {"N": "20"},
    "Losses":   {"N": "8"}
  }'

echo "PlayerProfiles seeded."
