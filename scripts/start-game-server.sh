#!/bin/bash
# Starts one game server container and prints its IP:port.
# Stop it later with: ./scripts/shutdown-servers.sh

set -e

GREEN='\033[0;32m'; BLUE='\033[0;34m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'

CLUSTER=$(aws cloudformation describe-stacks \
    --stack-name matchmaking-engine \
    --query "Stacks[0].Outputs[?OutputKey=='GameServerClusterName'].OutputValue" \
    --output text)

TASK_DEF=$(aws cloudformation describe-stacks \
    --stack-name matchmaking-engine \
    --query "Stacks[0].Outputs[?OutputKey=='GameServerTaskDefinitionArn'].OutputValue" \
    --output text)

echo -e "${BLUE}▶ Starting game server...${NC}"

RUN=$(aws ecs run-task --cluster "$CLUSTER" --task-definition "$TASK_DEF" --count 1)

FAILURES=$(echo "$RUN" | python3 -c \
    "import sys,json; print(len(json.load(sys.stdin).get('failures',[])))")
if [ "$FAILURES" -ne 0 ]; then
    REASON=$(echo "$RUN" | python3 -c \
        "import sys,json; f=json.load(sys.stdin)['failures'][0]; print(f.get('reason','unknown'))")
    echo -e "${RED}❌ RunTask failed: $REASON${NC}"; exit 1
fi

TASK_ARN=$(echo "$RUN" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['tasks'][0]['taskArn'])")

# Wait for RUNNING
PREV=""
while true; do
    TASK=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK_ARN")
    STATUS=$(echo "$TASK" | python3 -c \
        "import sys,json; print(json.load(sys.stdin)['tasks'][0]['lastStatus'])")
    [ "$STATUS" != "$PREV" ] && echo "  $STATUS"
    PREV="$STATUS"
    [ "$STATUS" = "RUNNING" ] && break
    [ "$STATUS" = "STOPPED" ] && { echo -e "${RED}❌ Task stopped unexpectedly.${NC}"; exit 1; }
    sleep 2
done

# Get host port from network bindings
PORT=$(echo "$TASK" | python3 -c "
import sys,json
task = json.load(sys.stdin)['tasks'][0]
for c in task.get('containers', []):
    for b in c.get('networkBindings', []):
        if b.get('protocol') == 'udp' and b.get('containerPort') == 26000:
            print(b['hostPort']); exit()
")

# Get public IP via container instance → EC2 instance
CI_ARN=$(echo "$TASK" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['tasks'][0]['containerInstanceArn'])")
EC2_ID=$(aws ecs describe-container-instances \
    --cluster "$CLUSTER" --container-instances "$CI_ARN" \
    --query "containerInstances[0].ec2InstanceId" --output text)
IP=$(aws ec2 describe-instances --instance-ids "$EC2_ID" \
    --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

echo ""
echo -e "${GREEN}${BOLD}  Server ready: $IP:$PORT${NC}"
echo ""
echo "  Connect with:  redeclipse +connect $IP +port $PORT"
echo "  Stop with:     ./scripts/shutdown-servers.sh"
echo ""
