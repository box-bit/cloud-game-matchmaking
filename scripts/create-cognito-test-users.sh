#!/bin/bash
set -e # Stop on any error

echo "Fetching Cognito IDs from CloudFormation..."

USER_POOL_ID=$(aws cloudformation describe-stacks \
    --stack-name matchmaking-engine \
    --query "Stacks[0].Outputs[?OutputKey=='UserPoolId'].OutputValue" \
    --output text)

CLIENT_ID=$(aws cloudformation describe-stacks \
    --stack-name matchmaking-engine \
    --query "Stacks[0].Outputs[?OutputKey=='UserPoolClientId'].OutputValue" \
    --output text)

echo "User Pool ID : $USER_POOL_ID"
echo "Client ID    : $CLIENT_ID"

EMAIL="testplayer@example.com"
PASSWORD="TestPass123"

echo ""
echo "Registering user $EMAIL..."
aws cognito-idp sign-up \
    --client-id "$CLIENT_ID" \
    --username "$EMAIL" \
    --password "$PASSWORD"

echo "Confirming user (skipping email verification)..."
aws cognito-idp admin-confirm-sign-up \
    --user-pool-id "$USER_POOL_ID" \
    --username "$EMAIL"

echo ""
echo "User $EMAIL created and confirmed."
