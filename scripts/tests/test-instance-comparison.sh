#!/bin/bash
# =============================================================================
# test-instance-comparison.sh
#
# Step 1 — Create a new EC2 instance via ASG scale-out.
#           Measure time until the instance registers with ECS.
# Step 2 — Start the first container on that instance.
#           Docker pulls the image from ECR (no local cache yet).
#           Measure time until the container is RUNNING.
# Step 3 — Start a second container on the same instance.
#           Docker uses the locally cached image, no pull needed.
#           Measure time until the container is RUNNING.
#
# Metrics produced:
#   - EC2 provisioning time
#   - First container start time  (ECR pull + process start)
#   - ECR pull duration           (estimated: step2 − step3)
#   - Second container start time (process start only)
#   - Total time from scale-out to first server ready
#   - CPU credit balance before / after (t3 instances)
#
# Cleanup: both containers are stopped and the new EC2 instance is
# terminated automatically on exit (trap EXIT).
#
# AWS Academy safe: all AWS calls are sequential.
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
warn()  { echo -e "${YELLOW}  ⚠  $1${NC}"; }
info()  { echo "     $1"; }
hr()    { echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"; }
subhr() { echo "  ────────────────────────────────────────────────────────────"; }

TASK1_ARN=""
TASK2_ARN=""
NEW_EC2_ID=""

cleanup() {
    [ -n "$TASK1_ARN" ] && aws ecs stop-task --cluster "$CLUSTER" --task "$TASK1_ARN" \
        --reason "cleanup" > /dev/null 2>&1 || true
    [ -n "$TASK2_ARN" ] && aws ecs stop-task --cluster "$CLUSTER" --task "$TASK2_ARN" \
        --reason "cleanup" > /dev/null 2>&1 || true
    if [ -n "$NEW_EC2_ID" ]; then
        warn "Terminating new instance $NEW_EC2_ID..."
        aws autoscaling terminate-instance-in-auto-scaling-group \
            --instance-id "$NEW_EC2_ID" \
            --should-decrement-desired-capacity > /dev/null 2>&1 || true
        ok "Instance terminated."
    fi
}
trap cleanup EXIT

# ── Pre-flight ────────────────────────────────────────────────────────────────
step "Pre-flight"

CLUSTER=$(aws cloudformation describe-stacks \
    --stack-name matchmaking-engine \
    --query "Stacks[0].Outputs[?OutputKey=='GameServerClusterName'].OutputValue" \
    --output text)

TASK_DEF=$(aws cloudformation describe-stacks \
    --stack-name matchmaking-engine \
    --query "Stacks[0].Outputs[?OutputKey=='GameServerTaskDefinitionArn'].OutputValue" \
    --output text)

ASG_NAME=$(aws cloudformation describe-stack-resources \
    --stack-name matchmaking-engine \
    --logical-resource-id GameServerASG \
    --query "StackResources[0].PhysicalResourceId" \
    --output text)

ASG=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME")
CURRENT_DESIRED=$(echo "$ASG" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['AutoScalingGroups'][0]['DesiredCapacity'])")
ASG_MAX=$(echo "$ASG" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['AutoScalingGroups'][0]['MaxSize'])")

if [ "$CURRENT_DESIRED" -ge "$ASG_MAX" ]; then
    echo -e "${RED}  ❌ ASG is already at MaxSize ($ASG_MAX). Cannot create a new instance.${NC}"
    echo "     Increase MaxSize in template.yaml and run sam deploy, then retry."
    exit 1
fi

# Note all container instance ARNs that exist right now so we can detect the newcomer
EXISTING_CIS=$(aws ecs list-container-instances \
    --cluster "$CLUSTER" --query "containerInstanceArns" --output json)
EXISTING_COUNT=$(echo "$EXISTING_CIS" | python3 -c \
    "import sys,json; print(len(json.load(sys.stdin)))")

# Find an existing EC2 instance to read its type and initial credit balance
CREDITS_BEFORE="N/A"
INSTANCE_TYPE="unknown"
if [ "$EXISTING_COUNT" -gt 0 ]; then
    EXISTING_CI=$(echo "$EXISTING_CIS" | python3 -c \
        "import sys,json; print(json.load(sys.stdin)[0])")
    CI_DESC=$(aws ecs describe-container-instances \
        --cluster "$CLUSTER" --container-instances "$EXISTING_CI")
    EXISTING_EC2=$(echo "$CI_DESC" | python3 -c \
        "import sys,json; print(json.load(sys.stdin)['containerInstances'][0]['ec2InstanceId'])")
    INSTANCE_TYPE=$(aws ec2 describe-instances --instance-ids "$EXISTING_EC2" \
        --query "Reservations[0].Instances[0].InstanceType" --output text)

    if echo "$INSTANCE_TYPE" | grep -qE '^(t2|t3)\.'; then
        NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        TEN_AGO=$(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
        CDATA=$(aws cloudwatch get-metric-statistics \
            --namespace AWS/EC2 --metric-name CPUCreditBalance \
            --dimensions Name=InstanceId,Value="$EXISTING_EC2" \
            --start-time "$TEN_AGO" --end-time "$NOW" \
            --period 300 --statistics Average \
            --query "sort_by(Datapoints,&Timestamp)[-1:].[Average]" --output json)
        CP=$(echo "$CDATA" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
        [ "$CP" -gt 0 ] && CREDITS_BEFORE=$(echo "$CDATA" | python3 -c \
            "import sys,json; print(f\"{json.load(sys.stdin)[-1][0]:.1f}\")")
    fi
fi

ok "Cluster         : $CLUSTER"
info "Task definition : $TASK_DEF"
info "Instance type   : $INSTANCE_TYPE"
info "ASG             : desired=$CURRENT_DESIRED max=$ASG_MAX"
info "CPU credits     : $CREDITS_BEFORE (before test)"

# ── Step 1: Create a new EC2 instance ────────────────────────────────────────
step "Step 1 — Creating a new EC2 instance (ASG scale-out)"
info "Setting ASG desired capacity: $CURRENT_DESIRED → $((CURRENT_DESIRED + 1))"
info "Waiting for the instance to boot and register with ECS..."

T1_START=$(date +%s%3N)

aws autoscaling set-desired-capacity \
    --auto-scaling-group-name "$ASG_NAME" \
    --desired-capacity $(( CURRENT_DESIRED + 1 ))

# Poll until a new container instance appears
NEW_CI_ARN=""
POLL_TIMEOUT=300
while [ $(( ( $(date +%s%3N) - T1_START ) / 1000 )) -lt $POLL_TIMEOUT ]; do
    ALL_CIS=$(aws ecs list-container-instances \
        --cluster "$CLUSTER" --query "containerInstanceArns" --output json)

    NEW_CI_ARN=$(echo "$ALL_CIS" | python3 -c "
import sys, json
existing = $(echo "$EXISTING_CIS")
for arn in json.load(sys.stdin):
    if arn not in existing:
        print(arn); exit()
")
    ELAPSED=$(( ( $(date +%s%3N) - T1_START ) / 1000 ))
    TOTAL=$(echo "$ALL_CIS" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
    printf "  [%3ds] instances registered: %d\n" "$ELAPSED" "$TOTAL"
    [ -n "$NEW_CI_ARN" ] && break
    sleep 5
done

if [ -z "$NEW_CI_ARN" ]; then
    echo -e "${RED}  ❌ New instance did not register within ${POLL_TIMEOUT}s.${NC}"
    exit 1
fi

T1_END=$(date +%s%3N)
T1_S=$(( (T1_END - T1_START) / 1000 ))

# Get the EC2 instance ID of the new instance
NEW_CI_DESC=$(aws ecs describe-container-instances \
    --cluster "$CLUSTER" --container-instances "$NEW_CI_ARN")
NEW_EC2_ID=$(echo "$NEW_CI_DESC" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['containerInstances'][0]['ec2InstanceId'])")

ok "New instance ready: $NEW_EC2_ID"
ok "EC2 provisioning time: ${T1_S}s"

# ── Step 2: First container (ECR pull) ───────────────────────────────────────
step "Step 2 — First container on new instance (image pull from ECR)"
info "Docker has no local cache on this instance yet."
info "ECS will pull the image from ECR before starting the process."

T2_START=$(date +%s%3N)

RUN1=$(aws ecs run-task \
    --cluster "$CLUSTER" \
    --task-definition "$TASK_DEF" \
    --placement-constraints "type=memberOf,expression=ec2InstanceId == $NEW_EC2_ID" \
    --count 1)

F1=$(echo "$RUN1" | python3 -c \
    "import sys,json; print(len(json.load(sys.stdin).get('failures',[])))")
if [ "$F1" -ne 0 ]; then
    REASON=$(echo "$RUN1" | python3 -c \
        "import sys,json; f=json.load(sys.stdin)['failures'][0]; print(f.get('reason','unknown'))")
    echo -e "${RED}  ❌ RunTask failed: $REASON${NC}"; exit 1
fi

TASK1_ARN=$(echo "$RUN1" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['tasks'][0]['taskArn'])")

PREV=""
for i in $(seq 1 60); do
    STATUS=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK1_ARN" \
        --query "tasks[0].lastStatus" --output text 2>/dev/null || echo "UNKNOWN")
    ELAPSED=$(( ( $(date +%s%3N) - T2_START ) / 1000 ))
    [ "$STATUS" != "$PREV" ] && printf "  [%3ds] %s\n" "$ELAPSED" "$STATUS"
    PREV="$STATUS"
    [ "$STATUS" = "RUNNING" ] && break
    [ "$STATUS" = "STOPPED" ] && { warn "Task stopped unexpectedly."; exit 1; }
    sleep 2
done

T2_END=$(date +%s%3N)
T2_S=$(( (T2_END - T2_START) / 1000 ))
ok "Container 1 RUNNING in ${T2_S}s  (includes ECR image pull)"

# ── Step 3: Second container (cached) ────────────────────────────────────────
step "Step 3 — Second container on same instance (image already cached)"
info "Docker will reuse the locally cached image — no network pull."

T3_START=$(date +%s%3N)

RUN2=$(aws ecs run-task \
    --cluster "$CLUSTER" \
    --task-definition "$TASK_DEF" \
    --placement-constraints "type=memberOf,expression=ec2InstanceId == $NEW_EC2_ID" \
    --count 1)

F2=$(echo "$RUN2" | python3 -c \
    "import sys,json; print(len(json.load(sys.stdin).get('failures',[])))")
if [ "$F2" -ne 0 ]; then
    REASON=$(echo "$RUN2" | python3 -c \
        "import sys,json; f=json.load(sys.stdin)['failures'][0]; print(f.get('reason','unknown'))")
    echo -e "${RED}  ❌ RunTask failed: $REASON${NC}"; exit 1
fi

TASK2_ARN=$(echo "$RUN2" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['tasks'][0]['taskArn'])")

PREV=""
for i in $(seq 1 20); do
    STATUS=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK2_ARN" \
        --query "tasks[0].lastStatus" --output text 2>/dev/null || echo "UNKNOWN")
    ELAPSED=$(( ( $(date +%s%3N) - T3_START ) / 1000 ))
    [ "$STATUS" != "$PREV" ] && printf "  [%3ds] %s\n" "$ELAPSED" "$STATUS"
    PREV="$STATUS"
    [ "$STATUS" = "RUNNING" ] && break
    [ "$STATUS" = "STOPPED" ] && { warn "Task stopped unexpectedly."; exit 1; }
    sleep 2
done

T3_END=$(date +%s%3N)
T3_S=$(( (T3_END - T3_START) / 1000 ))
ok "Container 2 RUNNING in ${T3_S}s  (cached image, no pull)"

# ── CPU credits after ─────────────────────────────────────────────────────────
CREDITS_AFTER="N/A"
if echo "$INSTANCE_TYPE" | grep -qE '^(t2|t3)\.' && [ -n "$EXISTING_EC2" ]; then
    NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    TEN_AGO=$(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
    CDATA=$(aws cloudwatch get-metric-statistics \
        --namespace AWS/EC2 --metric-name CPUCreditBalance \
        --dimensions Name=InstanceId,Value="$EXISTING_EC2" \
        --start-time "$TEN_AGO" --end-time "$NOW" \
        --period 300 --statistics Average \
        --query "sort_by(Datapoints,&Timestamp)[-1:].[Average]" --output json)
    CP=$(echo "$CDATA" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
    [ "$CP" -gt 0 ] && CREDITS_AFTER=$(echo "$CDATA" | python3 -c \
        "import sys,json; print(f\"{json.load(sys.stdin)[-1][0]:.1f}\")")
fi

# ── Report ────────────────────────────────────────────────────────────────────
TOTAL_S=$(( T1_S + T2_S ))
ECR_PULL_S=$(( T2_S - T3_S ))

echo ""
hr
echo -e "${BOLD}  EC2 INSTANCE TEST REPORT${NC}"
echo -e "  $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo -e "  Instance type: $INSTANCE_TYPE  |  New EC2: $NEW_EC2_ID"
hr

echo ""
echo -e "  ${BOLD}Timing Breakdown${NC}"
subhr
printf "  %-40s ${CYAN}%3ds${NC}\n" "Step 1 — EC2 provisioning (boot + ECS):"  "$T1_S"
printf "  %-40s ${YELLOW}%3ds${NC}\n" "Step 2 — Container 1 (ECR pull + start):"  "$T2_S"
printf "  %-40s ${GREEN}%3ds${NC}\n"  "Step 3 — Container 2 (cached, no pull):"   "$T3_S"
subhr
printf "  %-40s ${BOLD}%3ds${NC}  ← worst-case player wait\n" \
    "Total (Step 1 + Step 2):" "$TOTAL_S"

echo ""
echo -e "  ${BOLD}Estimated ECR Pull Duration${NC}"
subhr
printf "  %-40s %3ds\n" "Container 1 time (pull + process start):" "$T2_S"
printf "  %-40s %3ds\n" "Container 2 time (process start only):"   "$T3_S"
printf "  %-40s ${YELLOW}%3ds${NC}  ← estimated image download\n" \
    "Difference (ECR pull estimate):" "$ECR_PULL_S"
info "The pull only happens once per EC2 instance lifetime."
info "Every container after the first one pays only the process start cost (~${T3_S}s)."

echo ""
echo -e "  ${BOLD}CPU Credits ($INSTANCE_TYPE)${NC}"
subhr
printf "  %-30s %s\n" "Before test:" "$CREDITS_BEFORE"
printf "  %-30s %s\n" "After test:"  "$CREDITS_AFTER"
if [ "$CREDITS_BEFORE" != "N/A" ] && [ "$CREDITS_AFTER" != "N/A" ]; then
    DELTA=$(python3 -c "print(f'{float(\"$CREDITS_BEFORE\") - float(\"$CREDITS_AFTER\"):.1f}')")
    printf "  %-30s %s\n" "Consumed:" "$DELTA"
fi
echo "  Note: CloudWatch basic monitoring has 5-min granularity."
echo "  The delta may not reflect this short test accurately."

echo ""
echo -e "  ${BOLD}Summary${NC}"
subhr
echo "  A new EC2 instance takes ${T1_S}s to be ready to accept containers."
echo "  The first container pays a one-time ECR pull cost (~${ECR_PULL_S}s)."
echo "  All subsequent containers on the same instance start in ~${T3_S}s."
echo ""
echo "  Worst-case: a player waits ~${TOTAL_S}s after being matched"
echo "  (only when the ASG must provision a completely new instance)."
echo "  Normal case: a player waits ~${T3_S}s"
echo "  (capacity already exists, image already cached)."
echo ""
hr
echo ""
echo -e "${GREEN}  Test complete. Cleaning up...${NC}"
echo ""
