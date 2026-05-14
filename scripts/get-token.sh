#!/bin/bash
set -e

echo "Fetching Cognito IDs from CloudFormation..."

USER_POOL_ID=$(aws cloudformation describe-stacks \
    --stack-name matchmaking-engine \
    --query "Stacks[0].Outputs[?OutputKey=='UserPoolId'].OutputValue" \
    --output text)

CLIENT_ID=$(aws cloudformation describe-stacks \
    --stack-name matchmaking-engine \
    --query "Stacks[0].Outputs[?OutputKey=='UserPoolClientId'].OutputValue" \
    --output text)

EMAIL="testplayer@example.com"
PASSWORD="TestPass123"

echo "Authenticating as $EMAIL..."

AUTH_RESULT=$(aws cognito-idp initiate-auth \
    --auth-flow USER_PASSWORD_AUTH \
    --client-id "$CLIENT_ID" \
    --auth-parameters USERNAME="$EMAIL",PASSWORD="$PASSWORD")

ID_TOKEN=$(echo "$AUTH_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['AuthenticationResult']['IdToken'])")
SUB=$(aws cognito-idp get-user \
    --access-token "$(echo "$AUTH_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['AuthenticationResult']['AccessToken'])")" \
    --query "UserAttributes[?Name=='sub'].Value" \
    --output text)

echo ""
echo "Token retrieved successfully."
echo ""
echo "── Sub (UserId for DynamoDB) ──────────────────────────────"
echo "$SUB"
echo ""
echo "── IdToken (paste after 'Bearer' in API calls) ────────────"
echo "$ID_TOKEN"
echo ""

# Save both to a local file for easy reuse in the same session
mkdir -p .session
echo "$ID_TOKEN" >.session/id_token.txt
echo "$SUB" >.session/sub.txt

echo "Both saved to .session/ for reuse in other scripts."
