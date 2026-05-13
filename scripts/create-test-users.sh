# 0. Automatically fetch the IDs from your CloudFormation stack
# Replace 'your-stack-name' with the actual name you used during sam deploy
USER_POOL_ID=$(aws cloudformation describe-stacks --stack-name matchmaking-engine --query "Stacks[0].Outputs[?OutputKey=='UserPoolId'].OutputValue" --output text)
CLIENT_ID=$(aws cloudformation describe-stacks --stack-name matchmaking-engine --query "Stacks[0].Outputs[?OutputKey=='UserPoolClientId'].OutputValue" --output text)

# Step 1: Register the user
aws cognito-idp sign-up \
    --client-id $CLIENT_ID \
    --username testplayer@example.com \
    --password TestPass123

# # Step 2: Confirm them
aws cognito-idp admin-confirm-sign-up \
    --user-pool-id $USER_POOL_ID \
    --username testplayer@example.com
