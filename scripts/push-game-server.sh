#!/bin/bash
set -e

STACK_NAME="matchmaking-engine"
REGION=$(aws configure get region)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

REPO_URI=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='GameServerRepositoryUri'].OutputValue" \
    --output text)

if [ -z "$REPO_URI" ]; then
    echo "Error: could not find GameServerRepositoryUri in stack $STACK_NAME outputs."
    echo "Make sure the stack is deployed before pushing the image."
    exit 1
fi

echo "Logging into ECR..."
aws ecr get-login-password --region "$REGION" \
    | docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"

echo "Building game-server image..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
docker build -t redeclipse-server "$SCRIPT_DIR/../game-server"

echo "Tagging and pushing to $REPO_URI:latest ..."
docker tag redeclipse-server:latest "$REPO_URI:latest"
docker push "$REPO_URI:latest"

echo ""
echo "Done. Image pushed to $REPO_URI:latest"
echo "ECS tasks will pull the new image on their next start."
