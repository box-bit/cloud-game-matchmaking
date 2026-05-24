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
TICKET_TIMEOUT      = 300


def elo_max_distance(created_at):
    elapsed = time.time() - created_at
    if elapsed < 60:
        return 200
    elif elapsed < 120:
        return 400
    return 800


# ── ECS helpers ───────────────────────────────────────────────────────────────

def get_in_use_task_arns(tickets_table):
    """Return the set of TaskArns already assigned to active SUCCEEDED tickets."""
    arns = set()
    kwargs = {
        "FilterExpression": Attr("Status").eq("SUCCEEDED") & Attr("TaskArn").exists(),
        "ProjectionExpression": "TaskArn",
    }
    while True:
        resp = tickets_table.scan(**kwargs)
        for item in resp.get("Items", []):
            if "TaskArn" in item:
                arns.add(item["TaskArn"])
        if not resp.get("LastEvaluatedKey"):
            break
        kwargs["ExclusiveStartKey"] = resp["LastEvaluatedKey"]
    return arns


def get_running_task_arns():
    """Return all RUNNING task ARNs in the cluster."""
    arns = []
    paginator = ecs.get_paginator("list_tasks")
    for page in paginator.paginate(cluster=ECS_CLUSTER, desiredStatus="RUNNING"):
        arns.extend(page["taskArns"])
    return arns


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

    # Find the UDP host port Docker assigned for container port 26000
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

    # Container instance ARN → EC2 instance ID → public IP
    ci_resp        = ecs.describe_container_instances(
        cluster=ECS_CLUSTER,
        containerInstances=[task["containerInstanceArn"]],
    )
    ec2_instance_id = ci_resp["containerInstances"][0]["ec2InstanceId"]

    ec2_resp   = ec2.describe_instances(InstanceIds=[ec2_instance_id])
    public_ip  = ec2_resp["Reservations"][0]["Instances"][0].get("PublicIpAddress")

    if not public_ip:
        logger.warning(f"EC2 instance {ec2_instance_id} has no public IP")
        return None, None

    return public_ip, host_port


def allocate_server(in_use_arns, locally_allocated):
    """
    Pick an idle running task or start a new one.
    Returns (ip, port, task_arn) or None if allocation fails.
    locally_allocated prevents re-using a task already assigned in this invocation.
    """
    excluded   = in_use_arns | locally_allocated
    running    = get_running_task_arns()
    idle_arn   = next((arn for arn in running if arn not in excluded), None)

    if not idle_arn:
        logger.info("No idle task available — starting a new one")
        idle_arn = start_new_task()
        if not idle_arn:
            logger.error("Server allocation failed")
            return None

    ip, port = get_task_endpoint(idle_arn)
    if not ip or not port:
        return None

    return ip, port, idle_arn


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

    logger.info(f"Found {len(tickets)} SEARCHING tickets")

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

    active.sort(key=lambda t: int(t.get("ELO", 1000)))

    in_use_arns       = get_in_use_task_arns(tickets_table)
    locally_allocated = set()
    unmatched         = []

    for ticket in active:
        partner = None
        for candidate in unmatched:
            max_dist = max(
                elo_max_distance(int(ticket.get("CreatedAt", now))),
                elo_max_distance(int(candidate.get("CreatedAt", now))),
            )
            if abs(int(ticket.get("ELO", 1000)) - int(candidate.get("ELO", 1000))) <= max_dist:
                partner = candidate
                break

        if partner:
            unmatched.remove(partner)

            result = allocate_server(in_use_arns, locally_allocated)
            if not result:
                # No server available this cycle — leave both tickets searching
                logger.warning("No server available, deferring this match to next cycle")
                unmatched.append(ticket)
                continue

            server_ip, server_port, task_arn = result
            locally_allocated.add(task_arn)
            matched_players = [ticket["UserId"], partner["UserId"]]

            for t in (ticket, partner):
                try:
                    tickets_table.update_item(
                        Key={"TicketId": t["TicketId"]},
                        UpdateExpression=(
                            "SET #s = :s, MatchedPlayers = :mp, "
                            "ServerIp = :ip, ServerPort = :port, TaskArn = :arn"
                        ),
                        ConditionExpression=Attr("Status").eq("SEARCHING"),
                        ExpressionAttributeNames={"#s": "Status"},
                        ExpressionAttributeValues={
                            ":s":   "SUCCEEDED",
                            ":mp":  matched_players,
                            ":ip":  server_ip,
                            ":port": server_port,
                            ":arn": task_arn,
                        },
                    )
                    logger.info(
                        f"Matched {t['TicketId']} → {server_ip}:{server_port} "
                        f"(task {task_arn})"
                    )
                except dynamo.meta.client.exceptions.ConditionalCheckFailedException:
                    logger.warning(f"Ticket {t['TicketId']} already updated, skipping")
        else:
            unmatched.append(ticket)

    logger.info(f"Run complete — {len(unmatched)} ticket(s) still searching")
    return {"statusCode": 200}
