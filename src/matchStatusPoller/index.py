import os
import time
import boto3
import logging
from boto3.dynamodb.conditions import Attr

logger = logging.getLogger()
logger.setLevel(logging.INFO)

dynamo = boto3.resource("dynamodb")

GAME_SERVER_IP = os.environ.get("GAME_SERVER_IP", "")
GAME_SERVER_PORT = int(os.environ.get("GAME_SERVER_PORT", "26000"))
TICKET_TIMEOUT = 300  # seconds before a SEARCHING ticket is marked TIMED_OUT


def elo_max_distance(created_at):
    """ELO tolerance expands the longer a player waits."""
    elapsed = time.time() - created_at
    if elapsed < 60:
        return 200
    elif elapsed < 120:
        return 400
    return 800


def handler(event, context):
    tickets_table = dynamo.Table(os.environ["TICKETS_TABLE"])

    # Scan all SEARCHING tickets, handling DynamoDB pagination
    tickets = []
    scan_kwargs = {"FilterExpression": Attr("Status").eq("SEARCHING")}
    while True:
        response = tickets_table.scan(**scan_kwargs)
        tickets.extend(response.get("Items", []))
        last_key = response.get("LastEvaluatedKey")
        if not last_key:
            break
        scan_kwargs["ExclusiveStartKey"] = last_key

    logger.info(f"Found {len(tickets)} SEARCHING tickets")

    now = time.time()

    # Time out stale tickets; keep the rest for matching
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
                pass  # already matched or cancelled between scan and update
        else:
            active.append(ticket)

    # Greedy ELO matching — sort so closest ELO players are adjacent
    active.sort(key=lambda t: int(t.get("ELO", 1000)))

    unmatched = []
    for ticket in active:
        partner = None
        for candidate in unmatched:
            # Use the looser range of the two so long-waiting players get priority
            max_dist = max(
                elo_max_distance(int(ticket.get("CreatedAt", now))),
                elo_max_distance(int(candidate.get("CreatedAt", now))),
            )
            if abs(int(ticket.get("ELO", 1000)) - int(candidate.get("ELO", 1000))) <= max_dist:
                partner = candidate
                break

        if partner:
            unmatched.remove(partner)
            matched_players = [ticket["UserId"], partner["UserId"]]
            for t in (ticket, partner):
                try:
                    tickets_table.update_item(
                        Key={"TicketId": t["TicketId"]},
                        UpdateExpression=(
                            "SET #s = :s, MatchedPlayers = :mp, "
                            "ServerIp = :ip, ServerPort = :port"
                        ),
                        ConditionExpression=Attr("Status").eq("SEARCHING"),
                        ExpressionAttributeNames={"#s": "Status"},
                        ExpressionAttributeValues={
                            ":s": "SUCCEEDED",
                            ":mp": matched_players,
                            ":ip": GAME_SERVER_IP,
                            ":port": GAME_SERVER_PORT,
                        },
                    )
                    logger.info(f"Matched ticket {t['TicketId']} → SUCCEEDED")
                except dynamo.meta.client.exceptions.ConditionalCheckFailedException:
                    logger.warning(f"Ticket {t['TicketId']} already updated, skipping")
        else:
            unmatched.append(ticket)

    logger.info(f"Run complete — {len(unmatched)} ticket(s) still searching")
    return {"statusCode": 200}
