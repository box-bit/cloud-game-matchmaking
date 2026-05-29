#!/bin/bash
# =============================================================================
# test-7server-cpu-load.sh
# Starts all 7 game server containers that fit on a t3.micro (7 × 128 MB =
# 896 MB out of 916 MB ECS-registered), then monitors CPU utilization and CPU
# credit consumption while all 7 are running.
#
# Timeline:
#   Phase 1 — Start 7 containers sequentially, record each startup time
#   Phase 2 — Monitor for 10 min: poll CloudWatch every 60 s
#   Phase 3 — Collect final metrics and credit delta
#   Report  — Startup times, CPU under full load, credit burn rate,
#             time-to-exhaustion projection
#
# AWS Academy safe: no parallel calls, no Lambda invocations.
# All 7 tasks are stopped in cleanup (trap EXIT).
#
# Total runtime: ~15–20 minutes.
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

TASK_ARNS=()

cleanup() {
    if [ "${#TASK_ARNS[@]}" -gt 0 ]; then
        echo ""
        warn "Stopping ${#TASK_ARNS[@]} test task(s)..."
        for arn in "${TASK_ARNS[@]}"; do
            aws ecs stop-task --cluster "$CLUSTER_NAME" --task "$arn" \
                --reason "test-7server-cpu-load.sh cleanup" > /dev/null 2>&1 || true
        done
        ok "All test tasks stopped."
    fi
}
trap cleanup EXIT

# ── Pre-flight ────────────────────────────────────────────────────────────────
step "Pre-flight"

CLUSTER_NAME=$(aws cloudformation describe-stacks \
    --stack-name matchmaking-engine \
    --query "Stacks[0].Outputs[?OutputKey=='GameServerClusterName'].OutputValue" \
    --output text)

TASK_DEF_ARN=$(aws cloudformation describe-stacks \
    --stack-name matchmaking-engine \
    --query "Stacks[0].Outputs[?OutputKey=='GameServerTaskDefinitionArn'].OutputValue" \
    --output text)

# Get the single EC2 instance in the cluster
CI_LIST=$(aws ecs list-container-instances \
    --cluster "$CLUSTER_NAME" --query "containerInstanceArns" --output json)
CI_COUNT=$(echo "$CI_LIST" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")

if [ "$CI_COUNT" -eq 0 ]; then
    echo -e "${RED}  ❌ No EC2 instances in the cluster.${NC}"; exit 1
fi
if [ "$CI_COUNT" -gt 1 ]; then
    warn "$CI_COUNT instances in cluster. This test is designed for 1 (t3.micro)."
    warn "Results will still be collected for instance 1."
fi

CI_ARN=$(echo "$CI_LIST" | python3 -c "import sys,json; print(json.load(sys.stdin)[0])")
CI_DESC=$(aws ecs describe-container-instances \
    --cluster "$CLUSTER_NAME" --container-instances "$CI_ARN")

EC2_ID=$(echo "$CI_DESC" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['containerInstances'][0]['ec2InstanceId'])")
REGISTERED_MEM=$(echo "$CI_DESC" | python3 -c "
import sys,json
for r in json.load(sys.stdin)['containerInstances'][0]['registeredResources']:
    if r['name']=='MEMORY': print(r['integerValue']); exit()")
REMAINING_MEM=$(echo "$CI_DESC" | python3 -c "
import sys,json
for r in json.load(sys.stdin)['containerInstances'][0]['remainingResources']:
    if r['name']=='MEMORY': print(r['integerValue']); exit()")
ALREADY_RUNNING=$(echo "$CI_DESC" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['containerInstances'][0]['runningTasksCount'])")

EC2_TYPE=$(aws ec2 describe-instances --instance-ids "$EC2_ID" \
    --query "Reservations[0].Instances[0].InstanceType" --output text)

MAX_CONTAINERS=$(python3 -c "import math; print(math.floor($REGISTERED_MEM / 128))")
AVAILABLE_SLOTS=$(python3 -c "import math; print(math.floor($REMAINING_MEM / 128))")
TARGET=7

ok "Instance        : $EC2_ID ($EC2_TYPE)"
info "Memory          : ${REMAINING_MEM} MB free / ${REGISTERED_MEM} MB registered"
info "Tasks running   : $ALREADY_RUNNING"
info "Containers that fit: $MAX_CONTAINERS max, $AVAILABLE_SLOTS slots free now"

if [ "$AVAILABLE_SLOTS" -lt "$TARGET" ]; then
    echo -e "${RED}  ❌ Only $AVAILABLE_SLOTS free slots — need $TARGET. Stop other tasks first.${NC}"
    exit 1
fi

# Read initial CPU credit balance
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TEN_AGO_ISO=$(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ)

INITIAL_CREDITS="N/A"
if echo "$EC2_TYPE" | grep -qE '^(t2|t3)\.'; then
    CRED_DATA=$(aws cloudwatch get-metric-statistics \
        --namespace AWS/EC2 --metric-name CPUCreditBalance \
        --dimensions Name=InstanceId,Value="$EC2_ID" \
        --start-time "$TEN_AGO_ISO" --end-time "$NOW_ISO" \
        --period 300 --statistics Average \
        --query "sort_by(Datapoints,&Timestamp)[-1:].[Average]" --output json)
    CRED_POINTS=$(echo "$CRED_DATA" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
    if [ "$CRED_POINTS" -gt 0 ]; then
        INITIAL_CREDITS=$(echo "$CRED_DATA" | python3 -c \
            "import sys,json; print(f\"{json.load(sys.stdin)[-1][0]:.1f}\")")
        ok "CPU credit balance (before): $INITIAL_CREDITS"
    else
        warn "No credit data yet (5-min intervals). Will read after containers start."
    fi
fi

# ── Phase 1: Start 7 containers ───────────────────────────────────────────────
step "Phase 1 — Starting $TARGET containers sequentially"
info "Each container takes ~30–60 s to reach RUNNING."
info "Total phase estimate: $((TARGET * 45)) s (~$((TARGET * 45 / 60)) min)"

PHASE1_START=$(date +%s)
declare -a STARTUP_TIMES

for n in $(seq 1 $TARGET); do
    echo ""
    echo -e "  ${CYAN}Container $n / $TARGET${NC}"
    T_START=$(date +%s%3N)

    RUN_RESP=$(aws ecs run-task \
        --cluster "$CLUSTER_NAME" \
        --task-definition "$TASK_DEF_ARN" \
        --count 1)

    FAILURES=$(echo "$RUN_RESP" | python3 -c \
        "import sys,json; print(len(json.load(sys.stdin).get('failures',[])))")
    if [ "$FAILURES" -ne 0 ]; then
        REASON=$(echo "$RUN_RESP" | python3 -c \
            "import sys,json; f=json.load(sys.stdin)['failures'][0]; print(f.get('reason','unknown'))")
        echo -e "  ${RED}  ❌ RunTask failed at container $n: $REASON${NC}"
        echo "  Stopping. Only $((n-1)) containers were started."
        break
    fi

    TASK_ARN=$(echo "$RUN_RESP" | python3 -c \
        "import sys,json; print(json.load(sys.stdin)['tasks'][0]['taskArn'])")
    TASK_ARNS+=("$TASK_ARN")

    # Poll until RUNNING
    REACHED=0
    for i in $(seq 1 40); do
        STATUS=$(aws ecs describe-tasks --cluster "$CLUSTER_NAME" --tasks "$TASK_ARN" \
            --query "tasks[0].lastStatus" --output text 2>/dev/null || echo "UNKNOWN")
        ELAPSED_S=$(( ( $(date +%s%3N) - T_START ) / 1000 ))
        printf "  [%3ds] %s\n" "$ELAPSED_S" "$STATUS"
        if [ "$STATUS" = "RUNNING" ]; then REACHED=1; break; fi
        if [ "$STATUS" = "STOPPED" ] || [ "$STATUS" = "DEPROVISIONING" ]; then
            warn "Task stopped unexpectedly."; break; fi
        sleep 2
    done

    T_END=$(date +%s%3N)
    DURATION_S=$(( (T_END - T_START) / 1000 ))
    STARTUP_TIMES+=("$DURATION_S")

    if [ "$REACHED" -eq 1 ]; then
        ok "Container $n RUNNING in ${DURATION_S} s"
    else
        warn "Container $n did not reach RUNNING"
    fi
done

PHASE1_END=$(date +%s)
PHASE1_TOTAL_S=$(( PHASE1_END - PHASE1_START ))
CONTAINERS_STARTED=${#TASK_ARNS[@]}

echo ""
ok "$CONTAINERS_STARTED / $TARGET containers started in ${PHASE1_TOTAL_S} s total"

# ── Phase 2: Monitor CPU for 10 minutes ──────────────────────────────────────
step "Phase 2 — Monitoring CPU for 10 minutes  (CloudWatch 5-min intervals)"
info "Polling every 60 s. Expect the first data point after ~5 min."

MONITOR_START=$(date +%s)
MONITOR_DURATION=600   # 10 minutes

printf "\n  %-8s %-12s %-12s %-12s %-16s %s\n" \
    "Elapsed" "CPU avg%" "CPU max%" "Credits" "Memory used" "Running tasks"
subhr

for tick in $(seq 1 10); do
    sleep 60

    ELAPSED=$(( $(date +%s) - MONITOR_START ))

    NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    FIFTEEN_AGO=$(date -u -d '15 minutes ago' +%Y-%m-%dT%H:%M:%SZ)

    # CPU utilization
    CPU_DATA=$(aws cloudwatch get-metric-statistics \
        --namespace AWS/EC2 --metric-name CPUUtilization \
        --dimensions Name=InstanceId,Value="$EC2_ID" \
        --start-time "$FIFTEEN_AGO" --end-time "$NOW_ISO" \
        --period 300 --statistics Average Maximum \
        --query "sort_by(Datapoints,&Timestamp)[*].[Average,Maximum]" --output json)
    CPU_POINTS=$(echo "$CPU_DATA" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
    CPU_AVG_NOW="N/A"; CPU_MAX_NOW="N/A"
    if [ "$CPU_POINTS" -gt 0 ]; then
        CPU_AVG_NOW=$(echo "$CPU_DATA" | python3 -c \
            "import sys,json; pts=json.load(sys.stdin); print(f'{pts[-1][0]:.2f}')")
        CPU_MAX_NOW=$(echo "$CPU_DATA" | python3 -c \
            "import sys,json; pts=json.load(sys.stdin); print(f'{max(p[1] for p in pts):.2f}')")
    fi

    # Credit balance
    CREDITS_NOW="N/A"
    if echo "$EC2_TYPE" | grep -qE '^(t2|t3)\.'; then
        CRED_DATA=$(aws cloudwatch get-metric-statistics \
            --namespace AWS/EC2 --metric-name CPUCreditBalance \
            --dimensions Name=InstanceId,Value="$EC2_ID" \
            --start-time "$FIFTEEN_AGO" --end-time "$NOW_ISO" \
            --period 300 --statistics Average \
            --query "sort_by(Datapoints,&Timestamp)[-1:].[Average]" --output json)
        CP=$(echo "$CRED_DATA" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
        if [ "$CP" -gt 0 ]; then
            CREDITS_NOW=$(echo "$CRED_DATA" | python3 -c \
                "import sys,json; print(f\"{json.load(sys.stdin)[-1][0]:.1f}\")")
        fi
    fi

    # Running task count
    CI_NOW=$(aws ecs describe-container-instances \
        --cluster "$CLUSTER_NAME" --container-instances "$CI_ARN" \
        --query "containerInstances[0].runningTasksCount" --output text 2>/dev/null || echo "?")

    # Memory used
    MEM_USED=$(python3 -c "print(f'{int(\"$CI_NOW\" if \"$CI_NOW\" != \"?\" else 0) * 128} MB')" 2>/dev/null || echo "N/A")

    printf "  %-8s %-12s %-12s %-12s %-16s %s\n" \
        "${ELAPSED}s" "$CPU_AVG_NOW" "$CPU_MAX_NOW" "$CREDITS_NOW" "$MEM_USED" "$CI_NOW"

    # Save last known values for the report
    FINAL_CPU_AVG="$CPU_AVG_NOW"
    FINAL_CPU_MAX="$CPU_MAX_NOW"
    FINAL_CREDITS="$CREDITS_NOW"
done

# ── Phase 3: Final metrics ────────────────────────────────────────────────────
step "Phase 3 — Final metrics"

NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TWENTY_AGO=$(date -u -d '20 minutes ago' +%Y-%m-%dT%H:%M:%SZ)

FULL_CPU=$(aws cloudwatch get-metric-statistics \
    --namespace AWS/EC2 --metric-name CPUUtilization \
    --dimensions Name=InstanceId,Value="$EC2_ID" \
    --start-time "$TWENTY_AGO" --end-time "$NOW_ISO" \
    --period 300 --statistics Average Maximum Minimum \
    --query "sort_by(Datapoints,&Timestamp)[*].[Timestamp,Average,Maximum,Minimum]" \
    --output json)

FULL_POINTS=$(echo "$FULL_CPU" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
SUMMARY_AVG="N/A"; SUMMARY_MAX="N/A"; SUMMARY_MIN="N/A"
if [ "$FULL_POINTS" -gt 0 ]; then
    SUMMARY_AVG=$(echo "$FULL_CPU" | python3 -c \
        "import sys,json; pts=json.load(sys.stdin); print(f'{sum(p[1] for p in pts)/len(pts):.2f}')")
    SUMMARY_MAX=$(echo "$FULL_CPU" | python3 -c \
        "import sys,json; pts=json.load(sys.stdin); print(f'{max(p[2] for p in pts):.2f}')")
    SUMMARY_MIN=$(echo "$FULL_CPU" | python3 -c \
        "import sys,json; pts=json.load(sys.stdin); print(f'{min(p[3] for p in pts):.2f}')")
fi

# Final credit balance
FINAL_CREDITS_END="N/A"
if echo "$EC2_TYPE" | grep -qE '^(t2|t3)\.'; then
    CRED_FINAL=$(aws cloudwatch get-metric-statistics \
        --namespace AWS/EC2 --metric-name CPUCreditBalance \
        --dimensions Name=InstanceId,Value="$EC2_ID" \
        --start-time "$TWENTY_AGO" --end-time "$NOW_ISO" \
        --period 300 --statistics Average \
        --query "sort_by(Datapoints,&Timestamp)[-1:].[Average]" --output json)
    CF_POINTS=$(echo "$CRED_FINAL" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
    if [ "$CF_POINTS" -gt 0 ]; then
        FINAL_CREDITS_END=$(echo "$CRED_FINAL" | python3 -c \
            "import sys,json; print(f\"{json.load(sys.stdin)[-1][0]:.1f}\")")
    fi
fi

ok "Final CPU avg: $SUMMARY_AVG%  max: $SUMMARY_MAX%  ($FULL_POINTS data point(s))"
ok "Final CPU credits: $FINAL_CREDITS_END"

# ── Report ────────────────────────────────────────────────────────────────────
echo ""
hr
echo -e "${BOLD}  7-SERVER CPU LOAD TEST REPORT${NC}"
echo -e "  $(date -u '+%Y-%m-%d %H:%M:%S UTC')  |  Instance: $EC2_ID ($EC2_TYPE)"
hr

echo ""
echo -e "  ${BOLD}Container Startup Times${NC}"
subhr
AVG_START=0
for i in "${!STARTUP_TIMES[@]}"; do
    n=$(( i + 1 ))
    T="${STARTUP_TIMES[$i]}"
    AVG_START=$(( AVG_START + T ))
    printf "  Container %d:  %d s\n" "$n" "$T"
done
if [ "$CONTAINERS_STARTED" -gt 0 ]; then
    AVG_START=$(( AVG_START / CONTAINERS_STARTED ))
    echo ""
    printf "  %-30s %d s\n" "Average per container:"     "$AVG_START"
    printf "  %-30s %d s  (~$((PHASE1_TOTAL_S / 60)) min)\n" "Total to all $CONTAINERS_STARTED running:" "$PHASE1_TOTAL_S"
fi

echo ""
echo -e "  ${BOLD}Memory Utilization${NC}"
subhr
TOTAL_RESERVED=$(( CONTAINERS_STARTED * 128 ))
MEM_PCT=$(python3 -c "print(f'{$TOTAL_RESERVED / $REGISTERED_MEM * 100:.1f}')")
printf "  %-30s %d MB\n" "ECS-registered memory:"    "$REGISTERED_MEM"
printf "  %-30s %d MB  (%d × 128 MB)\n" "Reserved by containers:" "$TOTAL_RESERVED" "$CONTAINERS_STARTED"
printf "  %-30s %s%%\n" "Memory utilization:"       "$MEM_PCT"
printf "  %-30s %d MB\n" "Remaining free:"          $(( REGISTERED_MEM - TOTAL_RESERVED ))

echo ""
echo -e "  ${BOLD}CPU Utilization (7 servers running)${NC}"
subhr
printf "  %-30s %s%%\n" "Average:" "$SUMMARY_AVG"
printf "  %-30s %s%%\n" "Maximum:" "$SUMMARY_MAX"
printf "  %-30s %s%%\n" "Minimum:" "$SUMMARY_MIN"
printf "  %-30s %d data point(s)  (5-min intervals)\n" "Measured over:" "$FULL_POINTS"
echo ""
echo "  t3.micro CPU baseline: 10% × 2 vCPU = 20% sustained."
if [ "$SUMMARY_AVG" != "N/A" ]; then
    ABOVE_BASELINE=$(python3 -c "
avg = float('$SUMMARY_AVG')
baseline = 20.0
diff = avg - baseline
print(f'{diff:.2f}' if diff > 0 else '0.00')
")
    if [ "$(python3 -c "print('yes' if float('$SUMMARY_AVG') > 20 else 'no')")" = "yes" ]; then
        echo -e "  ${YELLOW}Average ($SUMMARY_AVG%) > 20% baseline → spending CPU credits.${NC}"
    else
        echo -e "  ${GREEN}Average ($SUMMARY_AVG%) ≤ 20% baseline → accumulating CPU credits.${NC}"
    fi
fi

echo ""
echo -e "  ${BOLD}CPU Credit Balance${NC}"
subhr
printf "  %-30s %s\n" "Before test:"  "$INITIAL_CREDITS"
printf "  %-30s %s\n" "After test:"   "$FINAL_CREDITS_END"

if [ "$INITIAL_CREDITS" != "N/A" ] && [ "$FINAL_CREDITS_END" != "N/A" ]; then
    DELTA=$(python3 -c "
before = float('$INITIAL_CREDITS')
after  = float('$FINAL_CREDITS_END')
delta  = before - after
print(f'{delta:.1f}')
")
    DELTA_SIGN=$(python3 -c "print('+' if float('$FINAL_CREDITS_END') >= float('$INITIAL_CREDITS') else '-')")
    if [ "$DELTA_SIGN" = "-" ]; then
        echo -e "  ${YELLOW}Credits consumed during test: $DELTA${NC}"

        # Project time to exhaustion at this burn rate
        # Test ran for ~MONITOR_DURATION seconds
        BURN_PER_HOUR=$(python3 -c "
delta = float('$DELTA')
hrs   = $MONITOR_DURATION / 3600
if hrs > 0 and delta > 0:
    print(f'{delta / hrs:.1f}')
else:
    print('0')
")
        if [ "$BURN_PER_HOUR" != "0" ]; then
            HOURS_LEFT=$(python3 -c "
after = float('$FINAL_CREDITS_END')
rate  = float('$BURN_PER_HOUR')
print(f'{after / rate:.1f}' if rate > 0 else 'inf')
")
            printf "  %-30s %s credits/hr\n" "Estimated burn rate:" "$BURN_PER_HOUR"
            printf "  %-30s %s hours  (at current load)\n" "Time to credit exhaustion:" "$HOURS_LEFT"
            echo -e "  ${YELLOW}After exhaustion: instance throttled to 20% CPU (0.2 vCPU).${NC}"
        fi
    else
        ABS_DELTA=$(python3 -c "print(abs(float('$DELTA')))")
        echo -e "  ${GREEN}Credits gained during test: +${ABS_DELTA} (load below baseline)${NC}"
    fi
fi

echo ""
echo -e "  ${BOLD}Summary${NC}"
subhr
printf "  %-30s %d / 7\n"    "Containers started:"    "$CONTAINERS_STARTED"
printf "  %-30s %s%%\n"       "Memory utilization:"    "$MEM_PCT"
printf "  %-30s %s%%\n"       "CPU avg (full load):"   "$SUMMARY_AVG"
printf "  %-30s %s%%\n"       "CPU max (full load):"   "$SUMMARY_MAX"
printf "  %-30s %s credits\n" "CPU credit balance:"    "$FINAL_CREDITS_END"
echo ""
hr
echo ""
