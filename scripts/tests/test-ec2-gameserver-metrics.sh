#!/bin/bash
# =============================================================================
# test-ec2-gameserver-metrics.sh
# Measures warm pool allocation time, cold start time, EC2 CPU utilization,
# and provides a monthly cost estimate for the game server infrastructure.
#
# ALL operations are sequential — zero concurrent Lambda invocations, zero
# parallel ECS/EC2 calls. Safe for AWS Academy accounts.
#
# What this tests:
#   Phase 1 — Warm path: how long to resolve an already-running ECS task to
#             IP:port (the 4 serial AWS API calls allocate_server() makes).
#   Phase 2 — Cold start: how long from RunTask until the new container is
#             RUNNING on the existing EC2 instance (image already cached).
#   Phase 3 — CloudWatch CPU: utilization of the EC2 instance over the last
#             15 minutes (basic monitoring, 5-min granularity).
#   Report  — Timing results + pricing table.
#
# Prerequisites:
#   sam deploy has been run
#   Game server Docker image has been pushed to ECR
#   At least 1 EC2 instance is RUNNING in the ASG (warm pool = 2 tasks)
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

# ── Phase 0: CloudFormation outputs ──────────────────────────────────────────
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

# ── Warm pool pre-check ───────────────────────────────────────────────────────
step "Checking warm pool (ECS running tasks)"

RUNNING_ARNS_JSON=$(aws ecs list-tasks \
    --cluster "$CLUSTER_NAME" \
    --desired-status RUNNING \
    --query "taskArns" \
    --output json)

RUNNING_COUNT=$(echo "$RUNNING_ARNS_JSON" | python3 -c \
    "import sys,json; print(len(json.load(sys.stdin)))")

if [ "$RUNNING_COUNT" -eq 0 ]; then
    echo -e "${RED}  ❌ No running ECS tasks found.${NC}"
    echo "     The warm pool service (DesiredCount=2) may still be starting."
    echo "     Wait a minute and retry, or check: aws ecs describe-services --cluster $CLUSTER_NAME --services game-server-warm-pool"
    exit 1
fi

ok "$RUNNING_COUNT task(s) currently RUNNING  (warm pool target: 2)"

# ── Phase 1: Warm path timing ─────────────────────────────────────────────────
step "Phase 1 — Warm path: resolving an existing task to IP:port"
info "Simulates allocate_server() finding an idle task already in the warm pool."
info "Sequence: ListTasks → DescribeTasks → DescribeContainerInstances → DescribeInstances"

WARM_START_MS=$(date +%s%3N)

# Step 1: list running tasks, pick the first one
WARM_TASK_ARN=$(aws ecs list-tasks \
    --cluster "$CLUSTER_NAME" \
    --desired-status RUNNING \
    --query "taskArns[0]" \
    --output text)

# Step 2: describe_tasks → host UDP port + container instance ARN
TASK_DESC=$(aws ecs describe-tasks \
    --cluster "$CLUSTER_NAME" \
    --tasks "$WARM_TASK_ARN")

WARM_HOST_PORT=$(echo "$TASK_DESC" | python3 -c "
import sys, json
t = json.load(sys.stdin)['tasks'][0]
for c in t.get('containers', []):
    for b in c.get('networkBindings', []):
        if b.get('protocol') == 'udp' and b.get('containerPort') == 26000:
            print(b['hostPort'])
            exit()
print('N/A')
")

CI_ARN=$(echo "$TASK_DESC" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['tasks'][0]['containerInstanceArn'])")

TASK_STATUS=$(echo "$TASK_DESC" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['tasks'][0]['lastStatus'])")

# Step 3: describe_container_instances → EC2 instance ID
CI_DESC=$(aws ecs describe-container-instances \
    --cluster "$CLUSTER_NAME" \
    --container-instances "$CI_ARN")

EC2_INSTANCE_ID=$(echo "$CI_DESC" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['containerInstances'][0]['ec2InstanceId'])")

REGISTERED_MEMORY=$(echo "$CI_DESC" | python3 -c \
    "import sys,json
ci = json.load(sys.stdin)['containerInstances'][0]
for r in ci.get('registeredResources', []):
    if r['name'] == 'MEMORY':
        print(r['integerValue'])
        exit()
print('N/A')")

REMAINING_MEMORY=$(echo "$CI_DESC" | python3 -c \
    "import sys,json
ci = json.load(sys.stdin)['containerInstances'][0]
for r in ci.get('remainingResources', []):
    if r['name'] == 'MEMORY':
        print(r['integerValue'])
        exit()
print('N/A')")

RUNNING_TASKS_ON_CI=$(echo "$CI_DESC" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['containerInstances'][0]['runningTasksCount'])")

# Step 4: describe_instances → public IP
EC2_DESC=$(aws ec2 describe-instances --instance-ids "$EC2_INSTANCE_ID")

PUBLIC_IP=$(echo "$EC2_DESC" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['Reservations'][0]['Instances'][0].get('PublicIpAddress','N/A'))")

INSTANCE_TYPE=$(echo "$EC2_DESC" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['Reservations'][0]['Instances'][0]['InstanceType'])")

INSTANCE_STATE=$(echo "$EC2_DESC" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['Reservations'][0]['Instances'][0]['State']['Name'])")

WARM_END_MS=$(date +%s%3N)
WARM_TIME_MS=$(( WARM_END_MS - WARM_START_MS ))

ok "Resolved: ${PUBLIC_IP}:${WARM_HOST_PORT}  in ${WARM_TIME_MS} ms"
info "EC2 instance  : $EC2_INSTANCE_ID  ($INSTANCE_TYPE, $INSTANCE_STATE)"
info "Task status   : $TASK_STATUS"
info "Memory on EC2 : ${REMAINING_MEMORY} MB free / ${REGISTERED_MEMORY} MB total"
info "Tasks on EC2  : $RUNNING_TASKS_ON_CI running"

# ── Phase 2: Cold start timing ────────────────────────────────────────────────
step "Phase 2 — Cold start: RunTask → RUNNING (container on existing EC2)"
info "Starting a new game server container. Image is already cached on the EC2 instance."
info "This measures container creation time, NOT EC2 provisioning time."

COLD_START_MS=$(date +%s%3N)

RUN_RESP=$(aws ecs run-task \
    --cluster "$CLUSTER_NAME" \
    --task-definition "$TASK_DEF_ARN" \
    --count 1)

FAILURE_COUNT=$(echo "$RUN_RESP" | python3 -c \
    "import sys,json; print(len(json.load(sys.stdin).get('failures',[])))")

if [ "$FAILURE_COUNT" -ne 0 ]; then
    FAILURE_REASON=$(echo "$RUN_RESP" | python3 -c \
        "import sys,json; f=json.load(sys.stdin)['failures'][0]; print(f.get('reason','unknown'))")
    echo -e "${RED}  ❌ RunTask failed: $FAILURE_REASON${NC}"
    info "This may happen if the EC2 instance has no free memory for another container."
    COLD_TIME_MS="N/A"
    REACHED_RUNNING=0
else
    TEST_TASK_ARN=$(echo "$RUN_RESP" | python3 -c \
        "import sys,json; print(json.load(sys.stdin)['tasks'][0]['taskArn'])")

    info "Task launched: ${TEST_TASK_ARN##*/}"
    info "Polling every 2 s until RUNNING (max 60 s)..."
    echo ""

    REACHED_RUNNING=0
    PREV_STATUS=""
    TRANSITION_TIMES=()
    T_PROVISIONING=""
    T_PENDING=""
    T_RUNNING=""

    for i in $(seq 1 30); do
        COLD_STATUS=$(aws ecs describe-tasks \
            --cluster "$CLUSTER_NAME" \
            --tasks "$TEST_TASK_ARN" \
            --query "tasks[0].lastStatus" \
            --output text 2>/dev/null || echo "UNKNOWN")

        ELAPSED_S=$(( ( $(date +%s%3N) - COLD_START_MS ) / 1000 ))
        printf "  [%3ds] %s\n" "$ELAPSED_S" "$COLD_STATUS"

        if [ "$COLD_STATUS" != "$PREV_STATUS" ]; then
            case "$COLD_STATUS" in
                PROVISIONING) T_PROVISIONING=$ELAPSED_S ;;
                PENDING)      T_PENDING=$ELAPSED_S ;;
                RUNNING)      T_RUNNING=$ELAPSED_S ;;
            esac
            PREV_STATUS="$COLD_STATUS"
        fi

        if [ "$COLD_STATUS" = "RUNNING" ]; then
            REACHED_RUNNING=1
            break
        fi
        if [ "$COLD_STATUS" = "STOPPED" ] || [ "$COLD_STATUS" = "DEPROVISIONING" ]; then
            warn "Task stopped unexpectedly."
            break
        fi
        sleep 2
    done

    COLD_END_MS=$(date +%s%3N)
    COLD_TIME_MS=$(( COLD_END_MS - COLD_START_MS ))

    echo ""
    if [ "$REACHED_RUNNING" -eq 1 ]; then
        ok "Container RUNNING after ${COLD_TIME_MS} ms  (~$((COLD_TIME_MS / 1000)) s)"
        [ -n "$T_PROVISIONING" ] && info "  → PROVISIONING at ${T_PROVISIONING}s"
        [ -n "$T_PENDING"      ] && info "  → PENDING       at ${T_PENDING}s"
        [ -n "$T_RUNNING"      ] && info "  → RUNNING       at ${T_RUNNING}s"
    else
        warn "Container did NOT reach RUNNING within 60 s (last status: $COLD_STATUS)"
        COLD_TIME_MS="timeout (>60 s)"
    fi
fi

# ── Phase 3: CloudWatch CPU metrics ──────────────────────────────────────────
step "Phase 3 — CloudWatch CPU utilization (last 15 min, 5-min periods)"
info "Instance: $EC2_INSTANCE_ID  ($INSTANCE_TYPE)"
info "EC2 basic monitoring publishes at 5-min granularity — up to 3 data points expected."

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
    warn "No CPU data points found for the last 15 min."
    warn "This is normal if the instance was just started. Check again in 5 minutes."
    CPU_AVG="N/A"
    CPU_MAX="N/A"
    CPU_MIN="N/A"
else
    CPU_AVG=$(echo "$CPU_DATA" | python3 -c \
        "import sys,json; pts=json.load(sys.stdin); print(f'{sum(p[1] for p in pts)/len(pts):.2f}')")
    CPU_MAX=$(echo "$CPU_DATA" | python3 -c \
        "import sys,json; pts=json.load(sys.stdin); print(f'{max(p[2] for p in pts):.2f}')")
    CPU_MIN=$(echo "$CPU_DATA" | python3 -c \
        "import sys,json; pts=json.load(sys.stdin); print(f'{min(p[3] for p in pts):.2f}')")
    ok "CPU over last 15 min:  avg ${CPU_AVG}%  |  max ${CPU_MAX}%  |  min ${CPU_MIN}%  ($CPU_POINT_COUNT point(s))"
    info "t3.micro CPU credit baseline: 10% of 1 vCPU"
    info "Values near 0–5% = idle warm pool containers (no active players)"
fi

# ── Final report ──────────────────────────────────────────────────────────────
echo ""
hr
echo -e "${BOLD}  EC2 GAME SERVER METRICS REPORT${NC}"
echo -e "  $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
hr

echo ""
echo -e "  ${BOLD}Infrastructure${NC}"
echo "  ─────────────────────────────────────────────────────────────────"
printf "  %-28s %s\n" "EC2 instance:"          "$EC2_INSTANCE_ID ($INSTANCE_TYPE, $INSTANCE_STATE)"
printf "  %-28s %s\n" "Warm pool tasks running:" "$RUNNING_COUNT  (target: 2)"
printf "  %-28s %s MB free / %s MB total\n" "EC2 memory:" "$REMAINING_MEMORY" "$REGISTERED_MEMORY"

echo ""
echo -e "  ${BOLD}Timing Results${NC}"
echo "  ─────────────────────────────────────────────────────────────────"
printf "  %-36s ${GREEN}%s ms${NC}\n" "Warm path (resolve existing task):" "$WARM_TIME_MS"
if [ "$REACHED_RUNNING" -eq 1 ]; then
    printf "  %-36s ${CYAN}%s ms  (~%s s)${NC}\n" "Cold start (RunTask → RUNNING):" "$COLD_TIME_MS" "$((COLD_TIME_MS / 1000))"
else
    printf "  %-36s ${YELLOW}%s${NC}\n" "Cold start (RunTask → RUNNING):" "$COLD_TIME_MS"
fi

echo ""
echo -e "  ${BOLD}Warm path breakdown (4 serial AWS API calls):${NC}"
printf "  %-6s %-32s %s\n" "  1." "ECS ListTasks"              "→ find idle task ARN"
printf "  %-6s %-32s %s\n" "  2." "ECS DescribeTasks"          "→ host UDP port + container instance"
printf "  %-6s %-32s %s\n" "  3." "ECS DescribeContainerInstances" "→ EC2 instance ID"
printf "  %-6s %-32s %s\n" "  4." "EC2 DescribeInstances"      "→ public IP"
info ""
info "Note: these calls run in Lambda (same AWS region as ECS/EC2) so latency"
info "in production is lower than the ${WARM_TIME_MS} ms measured from a laptop."

echo ""
echo -e "  ${BOLD}CPU Utilization (EC2 $INSTANCE_TYPE, last 15 min)${NC}"
echo "  ─────────────────────────────────────────────────────────────────"
printf "  %-28s %s%%\n" "Average:" "$CPU_AVG"
printf "  %-28s %s%%\n" "Maximum:" "$CPU_MAX"
printf "  %-28s %s%%\n" "Minimum:" "$CPU_MIN"
printf "  %-28s %s\n"   "Data points:"   "$CPU_POINT_COUNT (5-min intervals)"

echo ""
echo -e "  ${BOLD}Capacity (t3.micro, 1 GB RAM)${NC}"
echo "  ─────────────────────────────────────────────────────────────────"
echo "  Each game server container reserves 128 MB."
echo "  After OS + ECS agent overhead (~350 MB), ~650 MB is available."
printf "  %-28s %s\n" "Containers per instance:"  "~5  (650 ÷ 128 MB)"
printf "  %-28s %s\n" "ASG max instances:"        "2"
printf "  %-28s %s\n" "Max concurrent servers:"   "~10  (2 × 5 containers)"
printf "  %-28s %s\n" "Max concurrent players:"   "~80  (10 servers × 8 players)"

echo ""
echo -e "  ${BOLD}Monthly Cost Estimate — us-east-1, on-demand${NC}"
echo "  ─────────────────────────────────────────────────────────────────"
printf "  %-40s %s\n" "EC2 t3.micro (730 h/month):"    "\$0.0104/h  →  \$7.59/month"
printf "  %-40s %s\n" "EBS root volume (8 GB gp3):"    "\$0.08/GB/month  →  \$0.64/month"
printf "  %-40s %s\n" "CloudWatch Logs (7-day ret.):"   "\$0.50/GB ingested  (low for idle)"
printf "  %-40s %s\n" "ECR image storage (~500 MB):"   "\$0.10/GB/month  →  \$0.05/month"
printf "  %-40s %s\n" "Data transfer (first 100 GB):"  "free"
echo "  ─────────────────────────────────────────────────────────────────"
printf "  %-40s ${GREEN}%s${NC}\n" "1 EC2 instance (minimum):"   "~\$8.28/month"
printf "  %-40s ${YELLOW}%s${NC}\n" "2 EC2 instances (ASG max):"  "~\$16.56/month"

echo ""
echo -e "  ${BOLD}Cost vs. Scale${NC}"
echo "  ─────────────────────────────────────────────────────────────────"
printf "  %-12s %-14s %-16s %s\n" "Instances" "Max servers" "Max players" "Monthly cost"
printf "  %-12s %-14s %-16s %s\n" "─────────" "───────────" "───────────" "────────────"
printf "  %-12s %-14s %-16s %s\n" "1"          "~5"          "~40"         "\$8.28"
printf "  %-12s %-14s %-16s %s\n" "2 (max)"    "~10"         "~80"         "\$16.56"

echo ""
echo -e "  ${BOLD}Notes${NC}"
echo "  • Warm pool allocation = 4 API calls (sub-second in Lambda / same region)."
echo "  • Cold start = container creation only; image is cached on EC2 after first pull."
echo "  • True EC2 cold start (new instance provisioned by ASG) adds ~90–150 s total:"
echo "      EC2 launch ~60 s + ECS agent registration ~20 s + image pull ~30–60 s."
echo "  • t3.micro uses burstable CPU credits; sustained high load depletes credits."
echo "  • Lambda, API Gateway, DynamoDB, EventBridge costs are negligible (~\$0–\$1/month)"
echo "    at this scale (well within free tier for Lambda/DynamoDB)."
echo ""
hr
echo ""

if [ "$REACHED_RUNNING" -eq 1 ]; then
    echo -e "${GREEN}  Test PASSED.${NC}"
    EXIT_CODE=0
else
    echo -e "${YELLOW}  Test completed with warnings — cold start did not reach RUNNING.${NC}"
    EXIT_CODE=1
fi

echo ""
exit $EXIT_CODE
