#!/bin/bash
# =============================================================================
# test-instance-comparison.sh
# Helps decide between small vs. large EC2 instances for hosting Red Eclipse
# game server containers.
#
# Live measurements (current instance):
#   Phase 1 — Container cold start : RunTask → RUNNING on the existing EC2
#   Phase 2 — EC2 scale-out        : ASG adds a new instance, time until ECS
#                                     registers it and a container can start
#   Phase 3 — Quality metrics      : CPU utilization + CPU credit balance
#
# Analytical report (all instance types):
#   Comparison table: cost, containers per instance, cost per game server,
#   CPU type, and a suitability verdict for this workload.
#
# AWS Academy safety:
#   All AWS calls are sequential — no concurrent Lambda invocations, no
#   parallel ECS/EC2 calls. Phase 2 temporarily sets ASG desired capacity to 2
#   (within the existing MaxSize=2) then terminates the new instance.
#   Net cost: ~$0.002 (a few minutes of t3.micro runtime).
#
# Prerequisites:
#   sam deploy has been run, at least 1 EC2 instance is RUNNING in the ASG.
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

step()   { echo -e "\n${BLUE}▶ $1${NC}"; }
ok()     { echo -e "${GREEN}  ✅ $1${NC}"; }
warn()   { echo -e "${YELLOW}  ⚠  $1${NC}"; }
info()   { echo "     $1"; }
hr()     { echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"; }
subhr()  { echo "  ────────────────────────────────────────────────────────────"; }

TEST_TASK_ARN=""
NEW_EC2_INSTANCE_ID=""
SCALEOUT_DONE=0

cleanup() {
    if [ -n "$TEST_TASK_ARN" ]; then
        aws ecs stop-task --cluster "$CLUSTER_NAME" --task "$TEST_TASK_ARN" \
            --reason "test-instance-comparison.sh cleanup" > /dev/null 2>&1 || true
        TEST_TASK_ARN=""
    fi
    if [ -n "$NEW_EC2_INSTANCE_ID" ]; then
        warn "Terminating scale-out instance $NEW_EC2_INSTANCE_ID..."
        aws autoscaling terminate-instance-in-auto-scaling-group \
            --instance-id "$NEW_EC2_INSTANCE_ID" \
            --should-decrement-desired-capacity > /dev/null 2>&1 || true
        NEW_EC2_INSTANCE_ID=""
    fi
}
trap cleanup EXIT

# ── Pre-flight ────────────────────────────────────────────────────────────────
step "Pre-flight: fetching infrastructure details"

CLUSTER_NAME=$(aws cloudformation describe-stacks \
    --stack-name matchmaking-engine \
    --query "Stacks[0].Outputs[?OutputKey=='GameServerClusterName'].OutputValue" \
    --output text)

TASK_DEF_ARN=$(aws cloudformation describe-stacks \
    --stack-name matchmaking-engine \
    --query "Stacks[0].Outputs[?OutputKey=='GameServerTaskDefinitionArn'].OutputValue" \
    --output text)

ASG_NAME=$(aws cloudformation describe-stack-resources \
    --stack-name matchmaking-engine \
    --logical-resource-id GameServerASG \
    --query "StackResources[0].PhysicalResourceId" \
    --output text)

ASG_INFO=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME")

ASG_DESIRED=$(echo "$ASG_INFO" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['AutoScalingGroups'][0]['DesiredCapacity'])")
ASG_MIN=$(echo "$ASG_INFO" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['AutoScalingGroups'][0]['MinSize'])")
ASG_MAX=$(echo "$ASG_INFO" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['AutoScalingGroups'][0]['MaxSize'])")

# Find the running EC2 instance in the cluster
CI_ARNS=$(aws ecs list-container-instances \
    --cluster "$CLUSTER_NAME" --query "containerInstanceArns" --output json)
CI_COUNT=$(echo "$CI_ARNS" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")

if [ "$CI_COUNT" -eq 0 ]; then
    echo -e "${RED}  ❌ No EC2 instances registered to the ECS cluster.${NC}"
    exit 1
fi

ORIG_CI_ARN=$(echo "$CI_ARNS" | python3 -c "import sys,json; print(json.load(sys.stdin)[0])")
CI_DESC=$(aws ecs describe-container-instances \
    --cluster "$CLUSTER_NAME" --container-instances "$ORIG_CI_ARN")

ORIG_EC2_ID=$(echo "$CI_DESC" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['containerInstances'][0]['ec2InstanceId'])")
REGISTERED_MEM=$(echo "$CI_DESC" | python3 -c "
import sys,json
ci = json.load(sys.stdin)['containerInstances'][0]
for r in ci['registeredResources']:
    if r['name'] == 'MEMORY': print(r['integerValue']); exit()
print(0)")
REMAINING_MEM=$(echo "$CI_DESC" | python3 -c "
import sys,json
ci = json.load(sys.stdin)['containerInstances'][0]
for r in ci['remainingResources']:
    if r['name'] == 'MEMORY': print(r['integerValue']); exit()
print(0)")
RUNNING_TASKS=$(echo "$CI_DESC" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['containerInstances'][0]['runningTasksCount'])")

EC2_DESC=$(aws ec2 describe-instances --instance-ids "$ORIG_EC2_ID")
INSTANCE_TYPE=$(echo "$EC2_DESC" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['Reservations'][0]['Instances'][0]['InstanceType'])")
INSTANCE_STATE=$(echo "$EC2_DESC" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['Reservations'][0]['Instances'][0]['State']['Name'])")

ok "EC2 instance   : $ORIG_EC2_ID ($INSTANCE_TYPE, $INSTANCE_STATE)"
info "Memory         : ${REMAINING_MEM} MB free / ${REGISTERED_MEM} MB ECS-registered"
info "Running tasks  : $RUNNING_TASKS"
info "ASG            : $ASG_NAME  (desired=$ASG_DESIRED min=$ASG_MIN max=$ASG_MAX)"

# ── Phase 1: Container cold start ─────────────────────────────────────────────
step "Phase 1 — Container cold start: RunTask → RUNNING (on existing EC2)"
info "Image is cached on EC2 after the first pull — measures container creation only."

COLD_START_MS=$(date +%s%3N)
RUN_RESP=$(aws ecs run-task --cluster "$CLUSTER_NAME" --task-definition "$TASK_DEF_ARN" --count 1)
FAILURE_COUNT=$(echo "$RUN_RESP" | python3 -c \
    "import sys,json; print(len(json.load(sys.stdin).get('failures',[])))")

CONTAINER_COLD_MS="N/A"
CONTAINER_REACHED_RUNNING=0
T_PROVISIONING="" T_PENDING="" T_RUNNING_S=""

if [ "$FAILURE_COUNT" -ne 0 ]; then
    FAIL_REASON=$(echo "$RUN_RESP" | python3 -c \
        "import sys,json; f=json.load(sys.stdin)['failures'][0]; print(f.get('reason','unknown'))")
    warn "RunTask failed: $FAIL_REASON"
    info "Instance may be out of memory (${REMAINING_MEM} MB free, each container needs 128 MB)."
else
    TEST_TASK_ARN=$(echo "$RUN_RESP" | python3 -c \
        "import sys,json; print(json.load(sys.stdin)['tasks'][0]['taskArn'])")

    info "Polling every 2 s (max 60 s)..."
    PREV_STATUS=""
    for i in $(seq 1 30); do
        STATUS=$(aws ecs describe-tasks --cluster "$CLUSTER_NAME" --tasks "$TEST_TASK_ARN" \
            --query "tasks[0].lastStatus" --output text 2>/dev/null || echo "UNKNOWN")
        ELAPSED_S=$(( ( $(date +%s%3N) - COLD_START_MS ) / 1000 ))
        printf "  [%3ds] %s\n" "$ELAPSED_S" "$STATUS"
        if [ "$STATUS" != "$PREV_STATUS" ]; then
            case "$STATUS" in
                PROVISIONING) T_PROVISIONING=$ELAPSED_S ;;
                PENDING)      T_PENDING=$ELAPSED_S ;;
                RUNNING)      T_RUNNING_S=$ELAPSED_S ;;
            esac
            PREV_STATUS="$STATUS"
        fi
        if [ "$STATUS" = "RUNNING" ]; then CONTAINER_REACHED_RUNNING=1; break; fi
        if [ "$STATUS" = "STOPPED" ] || [ "$STATUS" = "DEPROVISIONING" ]; then
            warn "Task stopped unexpectedly."; break; fi
        sleep 2
    done

    CONTAINER_COLD_MS=$(( $(date +%s%3N) - COLD_START_MS ))
    if [ "$CONTAINER_REACHED_RUNNING" -eq 1 ]; then
        ok "RUNNING in ${CONTAINER_COLD_MS} ms  (~${T_RUNNING_S} s)"
    else
        warn "Did not reach RUNNING within 60 s (last: $PREV_STATUS)"
    fi

    # Stop the test task now — we don't need it anymore
    aws ecs stop-task --cluster "$CLUSTER_NAME" --task "$TEST_TASK_ARN" \
        --reason "test-instance-comparison.sh phase 1 done" > /dev/null 2>&1 || true
    TEST_TASK_ARN=""
fi

# ── Phase 2: EC2 scale-out ────────────────────────────────────────────────────
step "Phase 2 — EC2 scale-out: ASG adds a new instance, ECS registers it"

EC2_SCALEOUT_S="N/A"
EC2_SCALEOUT_DONE=0

if [ "$ASG_DESIRED" -ge "$ASG_MAX" ]; then
    warn "ASG is already at MaxSize ($ASG_MAX). Skipping scale-out test."
    warn "To test scale-out, set MaxSize > DesiredCapacity in template.yaml and redeploy."
else
    NEW_DESIRED=$(( ASG_DESIRED + 1 ))
    info "Scaling ASG from $ASG_DESIRED → $NEW_DESIRED instances..."
    info "This takes 60–120 s. The new instance will be terminated after measurement."
    echo ""

    # Snapshot current container instance ARNs to detect the newcomer
    ORIG_CI_SET=$(aws ecs list-container-instances \
        --cluster "$CLUSTER_NAME" --query "taskArns" --output json 2>/dev/null || echo "[]")
    ORIG_CI_LIST=$(aws ecs list-container-instances \
        --cluster "$CLUSTER_NAME" --query "containerInstanceArns" --output json)

    SCALEOUT_START_MS=$(date +%s%3N)

    aws autoscaling set-desired-capacity \
        --auto-scaling-group-name "$ASG_NAME" \
        --desired-capacity "$NEW_DESIRED" > /dev/null

    # Poll until a new container instance appears in the cluster (max 5 min)
    MAX_WAIT_S=300
    POLL_INTERVAL=5
    ELAPSED=0
    NEW_CI_ARN=""

    while [ "$ELAPSED" -lt "$MAX_WAIT_S" ]; do
        CURRENT_CI_LIST=$(aws ecs list-container-instances \
            --cluster "$CLUSTER_NAME" --query "containerInstanceArns" --output json)
        CURRENT_COUNT=$(echo "$CURRENT_CI_LIST" | python3 -c \
            "import sys,json; print(len(json.load(sys.stdin)))")
        ORIG_COUNT=$(echo "$ORIG_CI_LIST" | python3 -c \
            "import sys,json; print(len(json.load(sys.stdin)))")

        ELAPSED=$(( ( $(date +%s%3N) - SCALEOUT_START_MS ) / 1000 ))
        printf "  [%3ds] container instances in cluster: %d / %d target\n" \
            "$ELAPSED" "$CURRENT_COUNT" "$NEW_DESIRED"

        if [ "$CURRENT_COUNT" -gt "$ORIG_COUNT" ]; then
            # Find the new container instance ARN
            NEW_CI_ARN=$(echo "$CURRENT_CI_LIST" | python3 -c "
import sys, json
orig_str = '''$(echo "$ORIG_CI_LIST" | python3 -c "import sys,json; print('\n'.join(json.load(sys.stdin)))")'''
orig = set(orig_str.strip().split('\n')) if orig_str.strip() else set()
current = json.load(sys.stdin)
for arn in current:
    if arn not in orig:
        print(arn)
        break
")
            EC2_SCALEOUT_S=$ELAPSED
            EC2_SCALEOUT_DONE=1
            break
        fi
        sleep $POLL_INTERVAL
    done

    if [ "$EC2_SCALEOUT_DONE" -eq 1 ] && [ -n "$NEW_CI_ARN" ]; then
        SCALEOUT_DONE=1
        ok "New container instance registered after ${EC2_SCALEOUT_S} s"

        # Get the new EC2 instance ID so we can terminate it in cleanup
        NEW_CI_DESC=$(aws ecs describe-container-instances \
            --cluster "$CLUSTER_NAME" --container-instances "$NEW_CI_ARN")
        NEW_EC2_INSTANCE_ID=$(echo "$NEW_CI_DESC" | python3 -c \
            "import sys,json; print(json.load(sys.stdin)['containerInstances'][0]['ec2InstanceId'])")
        info "New EC2 instance : $NEW_EC2_INSTANCE_ID  (will be terminated now)"

        # Time a container start on the new instance to get full "player wait" time
        info "Timing a container cold start on the new instance..."
        FULL_WAIT_START_MS=$(date +%s%3N)
        PLACE_RESP=$(aws ecs run-task \
            --cluster "$CLUSTER_NAME" \
            --task-definition "$TASK_DEF_ARN" \
            --placement-constraints type=memberOf,expression="ec2InstanceId == $NEW_EC2_INSTANCE_ID" \
            --count 1 2>/dev/null || echo '{"failures":[{"reason":"placement failed"}],"tasks":[]}')

        PLACE_FAILURES=$(echo "$PLACE_RESP" | python3 -c \
            "import sys,json; print(len(json.load(sys.stdin).get('failures',[])))")

        FULL_WAIT_S="N/A"
        if [ "$PLACE_FAILURES" -eq 0 ]; then
            PLACED_TASK_ARN=$(echo "$PLACE_RESP" | python3 -c \
                "import sys,json; print(json.load(sys.stdin)['tasks'][0]['taskArn'])")
            for i in $(seq 1 30); do
                TASK_STATUS=$(aws ecs describe-tasks --cluster "$CLUSTER_NAME" \
                    --tasks "$PLACED_TASK_ARN" --query "tasks[0].lastStatus" \
                    --output text 2>/dev/null || echo "UNKNOWN")
                FW_ELAPSED=$(( ( $(date +%s%3N) - FULL_WAIT_START_MS ) / 1000 ))
                printf "  [%3ds] container on new instance: %s\n" "$FW_ELAPSED" "$TASK_STATUS"
                if [ "$TASK_STATUS" = "RUNNING" ]; then
                    FULL_WAIT_S=$FW_ELAPSED
                    break
                fi
                if [ "$TASK_STATUS" = "STOPPED" ]; then break; fi
                sleep 2
            done
            # Stop this task before terminating the instance
            aws ecs stop-task --cluster "$CLUSTER_NAME" --task "$PLACED_TASK_ARN" \
                --reason "test cleanup" > /dev/null 2>&1 || true
        fi

        [ "$FULL_WAIT_S" != "N/A" ] && ok "Container RUNNING on new instance after ${FULL_WAIT_S} s (from RunTask)"
    else
        warn "New instance did not register within ${MAX_WAIT_S} s."
        # Restore desired capacity
        aws autoscaling set-desired-capacity \
            --auto-scaling-group-name "$ASG_NAME" \
            --desired-capacity "$ASG_DESIRED" > /dev/null 2>&1 || true
    fi
fi

# ── Phase 3: Quality metrics ──────────────────────────────────────────────────
step "Phase 3 — Quality metrics: CPU utilization + credit balance"
info "Instance: $ORIG_EC2_ID ($INSTANCE_TYPE)"

NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
FIFTEEN_AGO=$(date -u -d '15 minutes ago' +%Y-%m-%dT%H:%M:%SZ)

CPU_DATA=$(aws cloudwatch get-metric-statistics \
    --namespace AWS/EC2 --metric-name CPUUtilization \
    --dimensions Name=InstanceId,Value="$ORIG_EC2_ID" \
    --start-time "$FIFTEEN_AGO" --end-time "$NOW_ISO" \
    --period 300 --statistics Average Maximum \
    --query "sort_by(Datapoints,&Timestamp)[*].[Average,Maximum]" --output json)

CPU_POINT_COUNT=$(echo "$CPU_DATA" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
CPU_AVG="N/A"; CPU_MAX="N/A"
if [ "$CPU_POINT_COUNT" -gt 0 ]; then
    CPU_AVG=$(echo "$CPU_DATA" | python3 -c \
        "import sys,json; pts=json.load(sys.stdin); print(f'{sum(p[0] for p in pts)/len(pts):.2f}')")
    CPU_MAX=$(echo "$CPU_DATA" | python3 -c \
        "import sys,json; pts=json.load(sys.stdin); print(f'{max(p[1] for p in pts):.2f}')")
    ok "CPU utilization: avg ${CPU_AVG}%  max ${CPU_MAX}%  ($CPU_POINT_COUNT data point(s))"
else
    warn "No CPU data in the last 15 min (basic monitoring, 5-min intervals)."
fi

# CPU credit balance — only available for burstable (t2/t3) instances
CPU_CREDITS="N/A"
CREDIT_WARN=""
if echo "$INSTANCE_TYPE" | grep -qE '^(t2|t3)\.'; then
    CREDIT_DATA=$(aws cloudwatch get-metric-statistics \
        --namespace AWS/EC2 --metric-name CPUCreditBalance \
        --dimensions Name=InstanceId,Value="$ORIG_EC2_ID" \
        --start-time "$FIFTEEN_AGO" --end-time "$NOW_ISO" \
        --period 300 --statistics Average \
        --query "sort_by(Datapoints,&Timestamp)[-1:].[Average]" --output json)

    CREDIT_POINTS=$(echo "$CREDIT_DATA" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
    if [ "$CREDIT_POINTS" -gt 0 ]; then
        CPU_CREDITS=$(echo "$CREDIT_DATA" | python3 -c \
            "import sys,json; pts=json.load(sys.stdin); print(f'{pts[-1][0]:.1f}')")
        # t3.micro max credits = 144, warn if below 50% (72)
        IS_LOW=$(echo "$CPU_CREDITS" | python3 -c \
            "import sys; v=float(sys.stdin.read()); print('yes' if v < 72 else 'no')" 2>/dev/null || echo "no")
        if [ "$IS_LOW" = "yes" ]; then
            CREDIT_WARN="  ⚠ Low credits — CPU may be throttled to 10% baseline (0.2 vCPU)"
        fi
        ok "CPU credit balance: $CPU_CREDITS  (max 144 for t3.micro)"
        [ -n "$CREDIT_WARN" ] && warn "$CREDIT_WARN"
    else
        warn "No CPU credit data yet (5-min intervals, instance may be too new)."
    fi
fi

# ── Report ────────────────────────────────────────────────────────────────────
echo ""
hr
echo -e "${BOLD}  EC2 INSTANCE COMPARISON REPORT${NC}"
echo -e "  $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
hr

# ── Measured results ──────────────────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}Measured Results  (current instance: $INSTANCE_TYPE)${NC}"
subhr

# Container cold start
printf "  %-38s " "Container cold start (cached image):"
if [ "$CONTAINER_REACHED_RUNNING" -eq 1 ]; then
    echo -e "${GREEN}${CONTAINER_COLD_MS} ms  (~${T_RUNNING_S} s)${NC}"
    [ -n "$T_PROVISIONING" ] && info "    PROVISIONING at ${T_PROVISIONING}s  →  PENDING at ${T_PENDING}s  →  RUNNING at ${T_RUNNING_S}s"
else
    echo -e "${YELLOW}${CONTAINER_COLD_MS}${NC}"
fi

# EC2 scale-out
printf "  %-38s " "EC2 scale-out (new instance → ECS):"
if [ "$SCALEOUT_DONE" -eq 1 ]; then
    echo -e "${GREEN}${EC2_SCALEOUT_S} s${NC}"
    if [ "${FULL_WAIT_S}" != "N/A" ]; then
        printf "  %-38s ${GREEN}%s s${NC}\n" "  + container start on new instance:" "${FULL_WAIT_S}"
        TOTAL_WAIT=$(( EC2_SCALEOUT_S + FULL_WAIT_S ))
        printf "  %-38s ${CYAN}%s s${NC}  ← player wait time (worst case)\n" "  Total (new EC2 + container):" "$TOTAL_WAIT"
    fi
else
    echo -e "${YELLOW}not measured (ASG already at MaxSize or timed out)${NC}"
fi

# CPU + quality
printf "  %-38s " "CPU utilization (last 15 min avg):"
echo "${CPU_AVG}%"
printf "  %-38s " "CPU credit balance (burstable t3):"
echo "$CPU_CREDITS"
[ -n "$CREDIT_WARN" ] && warn "$CREDIT_WARN"

printf "  %-38s " "Memory used by containers:"
USED_MEM=$(( REGISTERED_MEM - REMAINING_MEM ))
CONTAINERS_RUNNING=$RUNNING_TASKS
echo "${USED_MEM} MB  (${RUNNING_TASKS} task(s) × 128 MB = $((RUNNING_TASKS * 128)) MB reserved)"

# ── Comparison table ──────────────────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}Instance Comparison Table  (us-east-1, on-demand, your task: 128 MB/container)${NC}"
subhr

# Overhead: ECS-optimized AL2023 reserves ~100 MB for ECS agent and system
# Containers = floor((total_ram_mb - 100) / 128)
# Prices as of 2025 us-east-1 on-demand

printf "  ${BOLD}%-13s %-5s %-7s %-8s %-9s %-12s %-17s %-11s${NC}\n" \
    "Type" "vCPU" "RAM" "\$/hr" "\$/month" "Containers" "\$/container/mo" "CPU type"
subhr

print_row() {
    TYPE=$1 VCPU=$2 RAM_MB=$3 PRICE_HR=$4 CPU_KIND=$5 MARK=$6
    CONTAINERS=$(python3 -c "import math; print(math.floor(($RAM_MB - 100) / 128))")
    PRICE_MO=$(python3 -c "print(f'{$PRICE_HR * 730:.2f}')")
    COST_PER_CTR=$(python3 -c "
c=$CONTAINERS
if c > 0:
    print(f'$' + f'{$PRICE_HR * 730 / c:.2f}')
else:
    print('N/A')
")
    RAM_LABEL="${RAM_MB}MB"
    [ $RAM_MB -ge 1024 ] && RAM_LABEL="$(( RAM_MB / 1024 ))GB"

    # Highlight current instance type
    PREFIX="  "
    [ "$TYPE" = "$INSTANCE_TYPE" ] && PREFIX="${CYAN}→ " && SUFFIX="${NC}" || SUFFIX=""

    printf "${PREFIX}%-13s %-5s %-7s %-8s %-9s %-12s %-17s %s${SUFFIX}\n" \
        "$TYPE" "$VCPU" "$RAM_LABEL" "\$$PRICE_HR" "\$$PRICE_MO" \
        "$CONTAINERS" "$COST_PER_CTR" "${CPU_KIND}${MARK}"
}

# t3 burstable family
print_row "t3.nano"    2   512  0.0052 "Burstable"  ""
print_row "t3.micro"   2  1024  0.0104 "Burstable"  ""
print_row "t3.small"   2  2048  0.0208 "Burstable"  ""
print_row "t3.medium"  2  4096  0.0416 "Burstable"  ""
print_row "t3.large"   2  8192  0.0832 "Burstable"  ""
echo ""

# Non-burstable (dedicated CPU) options
print_row "c6i.large"  2  4096  0.0850 "Dedicated"  "  ✦ compute"
print_row "c6i.xlarge" 4  8192  0.1700 "Dedicated"  "  ✦ compute"
print_row "m6i.large"  2  8192  0.0960 "Dedicated"  "  ✦ general"

subhr
echo "  → = current instance   ✦ = dedicated (non-burstable) CPU"
echo "  Containers = floor((RAM - 100 MB system overhead) / 128 MB per container)"

# ── ASG scale scenarios ───────────────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}Scale Scenarios  (current ASG config: max 2 instances)${NC}"
subhr
printf "  %-13s %-13s %-13s %-13s %s\n" \
    "Type" "1× servers" "1× players" "2× servers" "2× players"
subhr

print_scale() {
    TYPE=$1 RAM_MB=$2
    C=$(python3 -c "import math; print(math.floor(($RAM_MB - 100) / 128))")
    printf "  %-13s %-13s %-13s %-13s %s\n" \
        "$TYPE" "~$C" "~$((C * 8))" "~$((C * 2))" "~$((C * 2 * 8))"
}
print_scale "t3.nano"    512
print_scale "t3.micro"  1024
print_scale "t3.small"  2048
print_scale "t3.medium" 4096
print_scale "t3.large"  8192
print_scale "m6i.large" 8192

# ── CPU quality note ──────────────────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}CPU Quality — Burstable vs. Dedicated${NC}"
subhr
echo "  t3 instances earn CPU credits when idle and spend them under load."
echo "  t3.micro baseline: 10% × 2 vCPU = 0.2 vCPU sustained."
echo ""
echo "  Red Eclipse server (8 players) uses roughly 2–5% CPU per container."
echo "  7 containers on t3.micro = ~14–35% CPU total — close to the 20% baseline."
echo "  Under sustained load, credits deplete and the instance is throttled."
echo ""
echo "  Dedicated instances (c6i/m6i) have no credit mechanism: full CPU always."
echo "  For a game server, this means predictable tick-rate and no lag spikes."

# ── Recommendation ────────────────────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}Recommendation${NC}"
subhr

# Compute a simple recommendation based on current credit balance
if echo "$INSTANCE_TYPE" | grep -qE '^t3\.'; then
    IS_CREDIT_LOW="no"
    if [ "$CPU_CREDITS" != "N/A" ]; then
        IS_CREDIT_LOW=$(echo "$CPU_CREDITS" | python3 -c \
            "import sys; v=float(sys.stdin.read()); print('yes' if v < 72 else 'no')" 2>/dev/null || echo "no")
    fi

    if [ "$IS_CREDIT_LOW" = "yes" ]; then
        echo -e "  ${RED}${BOLD}⚠ Credit balance is low on the current $INSTANCE_TYPE.${NC}"
        echo "  The instance is spending more credits than it earns — game servers"
        echo "  may already be experiencing CPU throttling."
        echo ""
        echo -e "  Upgrade to ${CYAN}t3.medium${NC} (29 containers, \$0.98/container/mo) or"
        echo -e "  ${CYAN}m6i.large${NC} (63 containers, \$1.11/container/mo, dedicated CPU)."
    else
        echo "  Current $INSTANCE_TYPE CPU credits are healthy."
    fi
fi

echo ""
echo "  For ≤ 7 concurrent game servers   →  t3.micro   (\$7.59/mo, current)"
echo "  For ≤ 31 concurrent game servers  →  t3.medium  (\$30.37/mo, best cost/container)"
echo "  Production / no CPU throttle risk →  m6i.large  (\$70.08/mo, dedicated CPU)"
echo ""
echo "  Key insight: the container cold start time (~${T_RUNNING_S:-?} s for cached image) is"
echo "  the SAME regardless of instance type — it is container creation, not EC2 launch."

if [ "$SCALEOUT_DONE" -eq 1 ]; then
    echo ""
    echo "  The measured EC2 scale-out time (~${EC2_SCALEOUT_S} s to ECS registration) is also"
    echo "  broadly instance-type-agnostic — it depends on the AMI boot and ECS agent"
    echo "  startup time, not on CPU/RAM. Total worst-case player wait = ~${TOTAL_WAIT:-?} s."
fi

echo ""
hr
echo ""
echo -e "${GREEN}  Test complete.${NC}"
echo ""
