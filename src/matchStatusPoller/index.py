import os
import time
import boto3
import logging
from boto3.dynamodb.conditions import Attr

logger = logging.getLogger()
logger.setLevel(logging.INFO)

dynamo = boto3.resource("dynamodb")
ecs    = boto3.client("ecs")
ec2    = boto3.client("ec2")

ECS_CLUSTER         = os.environ.get("ECS_CLUSTER", "")
ECS_TASK_DEFINITION = os.environ.get("ECS_TASK_DEFINITION", "")
MATCH_SIZE          = int(os.environ.get("MATCH_SIZE", "8"))
TICKET_TIMEOUT      = 300


def elo_max_distance(created_at):
    elapsed = time.time() - created_at
    if elapsed < 60:
        return 200
    elif elapsed < 120:
        return 400
    return 800


# ── ECS helpers ───────────────────────────────────────────────────────────────


def start_new_task():
    """Launch a new ECS task and poll until RUNNING (max 20 s). Returns ARN or None."""
    resp = ecs.run_task(
        cluster=ECS_CLUSTER,
        taskDefinition=ECS_TASK_DEFINITION,
        count=1,
    )
    failures = resp.get("failures", [])
    if failures:
        logger.warning(f"RunTask failures: {failures}")
        return None

    tasks = resp.get("tasks", [])
    if not tasks:
        return None

    task_arn = tasks[0]["taskArn"]
    logger.info(f"Started task {task_arn}, waiting for RUNNING...")

    for _ in range(10):
        time.sleep(2)
        desc   = ecs.describe_tasks(cluster=ECS_CLUSTER, tasks=[task_arn])
        status = desc["tasks"][0]["lastStatus"]
        if status == "RUNNING":
            return task_arn
        if status in ("STOPPED", "DEPROVISIONING"):
            logger.warning(f"Task {task_arn} stopped before RUNNING")
            return None

    logger.warning(f"Task {task_arn} did not reach RUNNING within 20 s")
    return None


def get_task_endpoint(task_arn):
    """Return (public_ip, host_port) for a RUNNING task, or (None, None)."""
    desc  = ecs.describe_tasks(cluster=ECS_CLUSTER, tasks=[task_arn])
    tasks = desc.get("tasks", [])
    if not tasks or tasks[0]["lastStatus"] != "RUNNING":
        return None, None

    task = tasks[0]

    host_port = None
    for container in task.get("containers", []):
        for binding in container.get("networkBindings", []):
            if binding.get("protocol") == "udp" and binding.get("containerPort") == 26000:
                host_port = int(binding["hostPort"])
                break
        if host_port:
            break

    if not host_port:
        logger.warning(f"No UDP binding found for task {task_arn}")
        return None, None

    ci_resp         = ecs.describe_container_instances(
        cluster=ECS_CLUSTER,
        containerInstances=[task["containerInstanceArn"]],
    )
    ec2_instance_id = ci_resp["containerInstances"][0]["ec2InstanceId"]

    ec2_resp  = ec2.describe_instances(InstanceIds=[ec2_instance_id])
    public_ip = ec2_resp["Reservations"][0]["Instances"][0].get("PublicIpAddress")

    if not public_ip:
        logger.warning(f"EC2 instance {ec2_instance_id} has no public IP")
        return None, None

    return public_ip, host_port


def allocate_server():
    """Start a new ECS task. Returns (ip, port, task_arn) or None."""
    task_arn = start_new_task()
    if not task_arn:
        logger.error("Server allocation failed")
        return None
    ip, port = get_task_endpoint(task_arn)
    if not ip or not port:
        return None
    return ip, port, task_arn


# ── Main handler ──────────────────────────────────────────────────────────────

def handler(event, context):
    tickets_table = dynamo.Table(os.environ["TICKETS_TABLE"])

    # Scan all SEARCHING tickets (paginated)
    tickets     = []
    scan_kwargs = {"FilterExpression": Attr("Status").eq("SEARCHING")}
    while True:
        response = tickets_table.scan(**scan_kwargs)
        tickets.extend(response.get("Items", []))
        if not response.get("LastEvaluatedKey"):
            break
        scan_kwargs["ExclusiveStartKey"] = response["LastEvaluatedKey"]

    logger.info(f"Found {len(tickets)} SEARCHING tickets (need {MATCH_SIZE} to form a group)")

    now    = time.time()
    active = []

    for ticket in tickets:
        age = now - int(ticket.get("CreatedAt", now))
        if age > TICKET_TIMEOUT:
            try:
                tickets_table.update_item(
                    Key={"TicketId": ticket["TicketId"]},
                    UpdateExpression="SET #s = :s",
                    ConditionExpression=Attr("Status").eq("SEARCHING"),
                    ExpressionAttributeNames={"#s": "Status"},
                    ExpressionAttributeValues={":s": "TIMED_OUT"},
                )
                logger.info(f"Timed out ticket {ticket['TicketId']}")
            except dynamo.meta.client.exceptions.ConditionalCheckFailedException:
                pass
        else:
            active.append(ticket)

    # Sort by ELO so the sliding window always sees a contiguous ELO range
    active.sort(key=lambda t: int(t.get("ELO", 1000)))

    groups_formed = 0

    # Sliding-window group matching:
    # Advance i by MATCH_SIZE when a group is formed, by 1 when the front ticket
    # is incompatible with the window — leaving it for the next poller cycle.
    i = 0
    while i + MATCH_SIZE <= len(active):
        window     = active[i:i + MATCH_SIZE]
        elo_spread = int(window[-1].get("ELO", 1000)) - int(window[0].get("ELO", 1000))

        # Tolerance is the most lenient of the group: the ticket that has waited
        # the longest earns the widest window for everyone.
        tolerance = max(
            elo_max_distance(int(t.get("CreatedAt", now))) for t in window
        )

        if elo_spread > tolerance:
            i += 1   # front ticket incompatible — slide past it
            continue

        result = allocate_server()
        if not result:
            logger.warning("No server available — deferring this group to next cycle")
            i += MATCH_SIZE
            continue

        server_ip, server_port, task_arn = result
        matched_players = [t["UserId"] for t in window]

        logger.info(
            f"Forming group of {MATCH_SIZE}: ELO {window[0].get('ELO')}–"
            f"{window[-1].get('ELO')} (spread {elo_spread}, tol {tolerance}) "
            f"→ {server_ip}:{server_port}"
        )

        for ticket in window:
            try:
                tickets_table.update_item(
                    Key={"TicketId": ticket["TicketId"]},
                    UpdateExpression=(
                        "SET #s = :s, MatchedPlayers = :mp, "
                        "ServerIp = :ip, ServerPort = :port, TaskArn = :arn"
                    ),
                    ConditionExpression=Attr("Status").eq("SEARCHING"),
                    ExpressionAttributeNames={"#s": "Status"},
                    ExpressionAttributeValues={
                        ":s":    "SUCCEEDED",
                        ":mp":   matched_players,
                        ":ip":   server_ip,
                        ":port": server_port,
                        ":arn":  task_arn,
                    },
                )
                logger.info(f"Matched ticket {ticket['TicketId']} (ELO {ticket.get('ELO')})")
            except dynamo.meta.client.exceptions.ConditionalCheckFailedException:
                logger.warning(f"Ticket {ticket['TicketId']} already updated, skipping")

        groups_formed += 1
        i += MATCH_SIZE

    still_searching = len(active) - groups_formed * MATCH_SIZE
    logger.info(
        f"Run complete — {groups_formed} group(s) matched, "
        f"{still_searching} ticket(s) still searching"
    )
    return {"statusCode": 200}
