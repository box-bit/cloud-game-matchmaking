#!/bin/bash
# =============================================================================
# test-ec2-gameserver-metrics.sh
# Measures cold start time (RunTask → RUNNING), EC2 CPU utilization, and
# provides a monthly cost estimate for the game server infrastructure.
#
# ALL operations are sequential — zero concurrent Lambda invocations, zero
# parallel ECS/EC2 calls. Safe for AWS Academy accounts.
#
# What this tests:
#   Phase 1 — Cold start: how long from RunTask until the container is RUNNING
#             on the existing EC2 instance (image already cached from first pull).
#   Phase 2 — CloudWatch CPU: utilization of the EC2 instance over the last
#             15 minutes (basic monitoring, 5-min granularity).
#   Report  — Timing results + capacity + pricing table.
#
# Prerequisites:
#   sam deploy has been run
#   Game server Docker image has been pushed to ECR
#   At least 1 EC2 instance is RUNNING in the ASG
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

step()  { echo -e "\n${BLUE}▶ $1${NC}"; }
ok()    { echo -e "${GREEN}  ✅ $1${NC}"; }
warn()  { echo -e "${YELLOW}  ⚠  $1${NC}"; }
info()  { echo "     $1"; }
hr()    { echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"; }

TEST_TASK_ARN=""

cleanup() {
    if [ -n "$TEST_TASK_ARN" ]; then
        echo ""
        warn "Stopping test task (cleanup)..."
        aws ecs stop-task \
            --cluster "$CLUSTER_NAME" \
            --task "$TEST_TASK_ARN" \
            --reason "test-ec2-gameserver-metrics.sh cleanup" > /dev/null 2>&1 || true
        TEST_TASK_ARN=""
        ok "Test task stopped."
    fi
}
trap cleanup EXIT

# ── Pre-flight ────────────────────────────────────────────────────────────────
step "Fetching CloudFormation outputs"

CLUSTER_NAME=$(aws cloudformation describe-stacks \
    --stack-name matchmaking-engine \
    --query "Stacks[0].Outputs[?OutputKey=='GameServerClusterName'].OutputValue" \
    --output text)

TASK_DEF_ARN=$(aws cloudformation describe-stacks \
    --stack-name matchmaking-engine \
    --query "Stacks[0].Outputs[?OutputKey=='GameServerTaskDefinitionArn'].OutputValue" \
    --output text)

info "Cluster     : $CLUSTER_NAME"
info "Task def    : $TASK_DEF_ARN"

# Find the EC2 instance registered to the cluster
CONTAINER_INSTANCES=$(aws ecs list-container-instances \
    --cluster "$CLUSTER_NAME" \
    --query "containerInstanceArns" \
    --output json)

CI_COUNT=$(echo "$CONTAINER_INSTANCES" | python3 -c \
    "import sys,json; print(len(json.load(sys.stdin)))")

if [ "$CI_COUNT" -eq 0 ]; then
    echo -e "${RED}  ❌ No EC2 instances registered to the ECS cluster.${NC}"
    echo "     The ASG may still be launching. Check:"
    echo "     aws ecs list-container-instances --cluster $CLUSTER_NAME"
    exit 1
fi

CI_ARN=$(echo "$CONTAINER_INSTANCES" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)[0])")

CI_DESC=$(aws ecs describe-container-instances \
    --cluster "$CLUSTER_NAME" \
    --container-instances "$CI_ARN")

EC2_INSTANCE_ID=$(echo "$CI_DESC" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['containerInstances'][0]['ec2InstanceId'])")

REGISTERED_MEMORY=$(echo "$CI_DESC" | python3 -c "
import sys,json
ci = json.load(sys.stdin)['containerInstances'][0]
for r in ci.get('registeredResources', []):
    if r['name'] == 'MEMORY':
        print(r['integerValue'])
        exit()
print('N/A')")

REMAINING_MEMORY=$(echo "$CI_DESC" | python3 -c "
import sys,json
ci = json.load(sys.stdin)['containerInstances'][0]
for r in ci.get('remainingResources', []):
    if r['name'] == 'MEMORY':
        print(r['integerValue'])
        exit()
print('N/A')")

RUNNING_TASKS_ON_CI=$(echo "$CI_DESC" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['containerInstances'][0]['runningTasksCount'])")

EC2_DESC=$(aws ec2 describe-instances --instance-ids "$EC2_INSTANCE_ID")
INSTANCE_TYPE=$(echo "$EC2_DESC" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['Reservations'][0]['Instances'][0]['InstanceType'])")
INSTANCE_STATE=$(echo "$EC2_DESC" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['Reservations'][0]['Instances'][0]['State']['Name'])")
PUBLIC_IP=$(echo "$EC2_DESC" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['Reservations'][0]['Instances'][0].get('PublicIpAddress','N/A'))")

ok "EC2 instance  : $EC2_INSTANCE_ID ($INSTANCE_TYPE, $INSTANCE_STATE)"
info "Public IP     : $PUBLIC_IP"
info "Memory        : ${REMAINING_MEMORY} MB free / ${REGISTERED_MEMORY} MB total"
info "Tasks running : $RUNNING_TASKS_ON_CI"

# ── Phase 1: Cold start timing ────────────────────────────────────────────────
step "Phase 1 — Cold start: RunTask → RUNNING"
info "Launching a new game server container on the existing EC2 instance."
info "Docker image is already cached on EC2 after the first-ever pull."

COLD_START_MS=$(date +%s%3N)

RUN_RESP=$(aws ecs run-task \
    --cluster "$CLUSTER_NAME" \
    --task-definition "$TASK_DEF_ARN" \
    --count 1)

FAILURE_COUNT=$(echo "$RUN_RESP" | python3 -c \
    "import sys,json; print(len(json.load(sys.stdin).get('failures',[])))")

REACHED_RUNNING=0
COLD_TIME_MS="N/A"
T_PROVISIONING="" T_PENDING="" T_RUNNING=""

if [ "$FAILURE_COUNT" -ne 0 ]; then
    FAILURE_REASON=$(echo "$RUN_RESP" | python3 -c \
        "import sys,json; f=json.load(sys.stdin)['failures'][0]; print(f.get('reason','unknown'))")
    echo -e "${RED}  ❌ RunTask failed: $FAILURE_REASON${NC}"
    info "The EC2 instance may not have enough free memory for another container."
    info "Currently running: $RUNNING_TASKS_ON_CI task(s), ${REMAINING_MEMORY} MB free, each container needs 128 MB."
else
    TEST_TASK_ARN=$(echo "$RUN_RESP" | python3 -c \
        "import sys,json; print(json.load(sys.stdin)['tasks'][0]['taskArn'])")

    info "Task: ${TEST_TASK_ARN##*/}"
    info "Polling every 2 s (max 60 s)..."
    echo ""

    PREV_STATUS=""
    for i in $(seq 1 30); do
        STATUS=$(aws ecs describe-tasks \
            --cluster "$CLUSTER_NAME" \
            --tasks "$TEST_TASK_ARN" \
            --query "tasks[0].lastStatus" \
            --output text 2>/dev/null || echo "UNKNOWN")

        ELAPSED_S=$(( ( $(date +%s%3N) - COLD_START_MS ) / 1000 ))
        printf "  [%3ds] %s\n" "$ELAPSED_S" "$STATUS"

        if [ "$STATUS" != "$PREV_STATUS" ]; then
            case "$STATUS" in
                PROVISIONING) T_PROVISIONING=$ELAPSED_S ;;
                PENDING)      T_PENDING=$ELAPSED_S ;;
                RUNNING)      T_RUNNING=$ELAPSED_S ;;
            esac
            PREV_STATUS="$STATUS"
        fi

        if [ "$STATUS" = "RUNNING" ]; then
            REACHED_RUNNING=1
            break
        fi
        if [ "$STATUS" = "STOPPED" ] || [ "$STATUS" = "DEPROVISIONING" ]; then
            warn "Task stopped unexpectedly."
            break
        fi
        sleep 2
    done

    COLD_TIME_MS=$(( $(date +%s%3N) - COLD_START_MS ))
    echo ""
    if [ "$REACHED_RUNNING" -eq 1 ]; then
        ok "Container RUNNING after ${COLD_TIME_MS} ms  (~$((COLD_TIME_MS / 1000)) s)"
    else
        warn "Container did NOT reach RUNNING within 60 s (last: $PREV_STATUS)"
        COLD_TIME_MS="timeout (>60 s)"
    fi
fi

# ── Phase 2: CloudWatch CPU metrics ──────────────────────────────────────────
step "Phase 2 — CloudWatch CPU utilization (last 15 min)"
info "Instance: $EC2_INSTANCE_ID ($INSTANCE_TYPE)"
info "Basic EC2 monitoring publishes at 5-min intervals — up to 3 data points."

NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
FIFTEEN_AGO_ISO=$(date -u -d '15 minutes ago' +%Y-%m-%dT%H:%M:%SZ)

CPU_DATA=$(aws cloudwatch get-metric-statistics \
    --namespace AWS/EC2 \
    --metric-name CPUUtilization \
    --dimensions Name=InstanceId,Value="$EC2_INSTANCE_ID" \
    --start-time "$FIFTEEN_AGO_ISO" \
    --end-time "$NOW_ISO" \
    --period 300 \
    --statistics Average Maximum Minimum \
    --query "sort_by(Datapoints, &Timestamp)[*].[Timestamp,Average,Maximum,Minimum]" \
    --output json)

CPU_POINT_COUNT=$(echo "$CPU_DATA" | python3 -c \
    "import sys,json; print(len(json.load(sys.stdin)))")

if [ "$CPU_POINT_COUNT" -eq 0 ]; then
    warn "No CPU data points yet. Basic monitoring may not have published in this window."
    CPU_AVG="N/A"; CPU_MAX="N/A"; CPU_MIN="N/A"
else
    CPU_AVG=$(echo "$CPU_DATA" | python3 -c \
        "import sys,json; pts=json.load(sys.stdin); print(f'{sum(p[1] for p in pts)/len(pts):.2f}')")
    CPU_MAX=$(echo "$CPU_DATA" | python3 -c \
        "import sys,json; pts=json.load(sys.stdin); print(f'{max(p[2] for p in pts):.2f}')")
    CPU_MIN=$(echo "$CPU_DATA" | python3 -c \
        "import sys,json; pts=json.load(sys.stdin); print(f'{min(p[3] for p in pts):.2f}')")
    ok "CPU: avg ${CPU_AVG}%  max ${CPU_MAX}%  min ${CPU_MIN}%  ($CPU_POINT_COUNT data point(s))"
fi

# ── Report ────────────────────────────────────────────────────────────────────
echo ""
hr
echo -e "${BOLD}  EC2 GAME SERVER METRICS REPORT${NC}"
echo -e "  $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
hr

echo ""
echo -e "  ${BOLD}Infrastructure${NC}"
echo "  ────────────────────────────────────────────────────────────────"
printf "  %-28s %s\n" "EC2 instance:" "$EC2_INSTANCE_ID ($INSTANCE_TYPE, $INSTANCE_STATE)"
printf "  %-28s %s MB free / %s MB total\n" "EC2 memory:" "$REMAINING_MEMORY" "$REGISTERED_MEMORY"
printf "  %-28s %s\n" "Tasks running before test:" "$RUNNING_TASKS_ON_CI"

echo ""
echo -e "  ${BOLD}Cold Start Timing${NC}"
echo "  ────────────────────────────────────────────────────────────────"
if [ "$REACHED_RUNNING" -eq 1 ]; then
    printf "  %-28s ${GREEN}%s ms  (~%s s)${NC}\n" "RunTask → RUNNING:" "$COLD_TIME_MS" "$((COLD_TIME_MS / 1000))"
    [ -n "$T_PROVISIONING" ] && printf "  %-28s %s s\n" "  → PROVISIONING at:" "$T_PROVISIONING"
    [ -n "$T_PENDING"      ] && printf "  %-28s %s s\n" "  → PENDING at:"      "$T_PENDING"
    [ -n "$T_RUNNING"      ] && printf "  %-28s %s s\n" "  → RUNNING at:"      "$T_RUNNING"
else
    printf "  %-28s ${YELLOW}%s${NC}\n" "RunTask → RUNNING:" "$COLD_TIME_MS"
fi
echo ""
echo "  Every match start pays this cold start cost. The MatchStatusPoller"
echo "  polls every 2 s; the 20 s RunTask timeout in the Lambda sets the"
echo "  upper bound before a group is deferred to the next poller cycle."

echo ""
echo -e "  ${BOLD}CPU Utilization ($INSTANCE_TYPE, last 15 min)${NC}"
echo "  ────────────────────────────────────────────────────────────────"
printf "  %-28s %s%%\n" "Average:" "$CPU_AVG"
printf "  %-28s %s%%\n" "Maximum:" "$CPU_MAX"
printf "  %-28s %s%%\n" "Minimum:" "$CPU_MIN"
printf "  %-28s %s\n"   "Data points:" "$CPU_POINT_COUNT  (5-min intervals)"
echo "  t3.micro CPU credit baseline: 10% of 1 vCPU."

echo ""
echo -e "  ${BOLD}Capacity (t3.micro, 1 GB RAM)${NC}"
echo "  ────────────────────────────────────────────────────────────────"
echo "  Each game server container reserves 128 MB."
echo "  After OS + ECS agent overhead (~350 MB), ~650 MB is available."
printf "  %-28s %s\n" "Containers per instance:" "~5  (650 ÷ 128 MB)"
printf "  %-28s %s\n" "ASG max instances:"       "2"
printf "  %-28s %s\n" "Max concurrent servers:"  "~10  (2 × 5 containers)"
printf "  %-28s %s\n" "Max concurrent players:"  "~80  (10 servers × 8 players)"

echo ""
echo -e "  ${BOLD}Monthly Cost Estimate — us-east-1, on-demand${NC}"
echo "  ────────────────────────────────────────────────────────────────"
printf "  %-40s %s\n" "EC2 t3.micro (730 h/month):"     "\$0.0104/h  →  \$7.59/month"
printf "  %-40s %s\n" "EBS root volume (8 GB gp3):"     "\$0.08/GB/month  →  \$0.64/month"
printf "  %-40s %s\n" "CloudWatch Logs (7-day ret.):"   "\$0.50/GB ingested"
printf "  %-40s %s\n" "ECR image storage (~500 MB):"    "\$0.10/GB/month  →  \$0.05/month"
printf "  %-40s %s\n" "Data transfer (first 100 GB):"   "free"
echo "  ────────────────────────────────────────────────────────────────"
printf "  %-40s ${GREEN}%s${NC}\n" "1 EC2 instance (minimum):"   "~\$8.28/month"
printf "  %-40s ${YELLOW}%s${NC}\n" "2 EC2 instances (ASG max):"  "~\$16.56/month"

echo ""
echo -e "  ${BOLD}Cost vs. Scale${NC}"
echo "  ────────────────────────────────────────────────────────────────"
printf "  %-12s %-14s %-16s %s\n" "Instances" "Max servers" "Max players" "Monthly cost"
printf "  %-12s %-14s %-16s %s\n" "─────────" "───────────" "───────────" "────────────"
printf "  %-12s %-14s %-16s %s\n" "1"          "~5"          "~40"         "\$8.28"
printf "  %-12s %-14s %-16s %s\n" "2 (max)"    "~10"         "~80"         "\$16.56"
echo ""
hr
echo ""

if [ "$REACHED_RUNNING" -eq 1 ]; then
    echo -e "${GREEN}  Test PASSED.${NC}"
    EXIT_CODE=0
else
    echo -e "${YELLOW}  Test completed with warnings.${NC}"
    EXIT_CODE=1
fi

echo ""
exit $EXIT_CODE
