#!/bin/bash
# Stops all running ECS tasks and scales the ASG back to 1 instance.

set -e

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { echo -e "${BLUE}▶ $1${NC}"; }
ok()   { echo -e "${GREEN}  ✅ $1${NC}"; }
warn() { echo -e "${YELLOW}  ⚠  $1${NC}"; }

CLUSTER=$(aws cloudformation describe-stacks \
    --stack-name matchmaking-engine \
    --query "Stacks[0].Outputs[?OutputKey=='GameServerClusterName'].OutputValue" \
    --output text)

ASG_NAME=$(aws cloudformation describe-stack-resources \
    --stack-name matchmaking-engine \
    --logical-resource-id GameServerASG \
    --query "StackResources[0].PhysicalResourceId" \
    --output text)

# Stop all running tasks
info "Stopping all running ECS tasks..."
TASK_ARNS=$(aws ecs list-tasks --cluster "$CLUSTER" --desired-status RUNNING \
    --query "taskArns" --output json)
TASK_COUNT=$(echo "$TASK_ARNS" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")

if [ "$TASK_COUNT" -eq 0 ]; then
    warn "No running tasks found."
else
    echo "$TASK_ARNS" | python3 -c "import sys,json; [print(a) for a in json.load(sys.stdin)]" \
    | while read -r ARN; do
        aws ecs stop-task --cluster "$CLUSTER" --task "$ARN" \
            --reason "shutdown-servers.sh" > /dev/null
        echo "  stopped: ${ARN##*/}"
    done
    ok "Stopped $TASK_COUNT task(s)."
fi

# Scale ASG back to 1
info "Scaling ASG down to 1 instance..."
ASG_INFO=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME")
CURRENT=$(echo "$ASG_INFO" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['AutoScalingGroups'][0]['DesiredCapacity'])")
MIN=$(echo "$ASG_INFO" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['AutoScalingGroups'][0]['MinSize'])")

if [ "$CURRENT" -le "$MIN" ]; then
    warn "ASG already at minimum ($CURRENT instance). Nothing to scale down."
else
    aws autoscaling set-desired-capacity \
        --auto-scaling-group-name "$ASG_NAME" \
        --desired-capacity "$MIN"
    ok "ASG desired capacity set to $MIN (was $CURRENT). Extra instance(s) will terminate shortly."
fi

echo ""
ok "Done."
