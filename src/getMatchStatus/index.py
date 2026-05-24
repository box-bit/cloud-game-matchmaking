import json
import os
import boto3
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

dynamo = boto3.resource("dynamodb")

CORS_HEADERS = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Authorization,Content-Type",
    "Access-Control-Allow-Methods": "GET,OPTIONS",
}


def _response(status, body):
    return {
        "statusCode": status,
        "headers": CORS_HEADERS,
        "body": json.dumps(body),
    }


def _lookup_usernames(user_ids):
    """Resolve each user id to {userId, username}; fall back to the id when missing."""
    if not user_ids:
        return []
    try:
        player_table = dynamo.Table(os.environ["PLAYER_TABLE"])
        names = {}
        # BatchGetItem caps at 100 keys; matches only have 2, so a single call is fine.
        resp = dynamo.batch_get_item(
            RequestItems={
                player_table.name: {
                    "Keys": [{"UserId": uid} for uid in user_ids],
                    "ProjectionExpression": "UserId, Username",
                }
            }
        )
        for item in resp.get("Responses", {}).get(player_table.name, []):
            names[item["UserId"]] = item.get("Username") or ""
        return [{"userId": uid, "username": names.get(uid, "") or uid} for uid in user_ids]
    except Exception as e:
        logger.warning(f"Could not resolve usernames: {e}")
        return [{"userId": uid, "username": uid} for uid in user_ids]


def handler(event, context):
    try:
        claims = event["requestContext"]["authorizer"]["claims"]
        user_id = claims["sub"]
        ticket_id = event["pathParameters"]["ticketId"]

        tickets_table = dynamo.Table(os.environ["TICKETS_TABLE"])
        response = tickets_table.get_item(Key={"TicketId": ticket_id})

        if "Item" not in response:
            return _response(404, {"error": "Ticket not found"})

        ticket = response["Item"]

        if ticket.get("UserId") != user_id:
            return _response(403, {"error": "Forbidden"})

        matched_ids = ticket.get("MatchedPlayers", []) or []
        body = {
            "ticketId": ticket_id,
            "status": ticket.get("Status"),
            "userId": ticket.get("UserId"),
            "elo": int(ticket.get("ELO", 0)),
            "matchedPlayers": matched_ids,
            "players": _lookup_usernames(matched_ids),
        }

        if ticket.get("ServerIp"):
            body["serverIp"] = ticket["ServerIp"]
            body["serverPort"] = int(ticket.get("ServerPort", 26000))

        return _response(200, body)

    except KeyError as e:
        return _response(400, {"error": f"Missing field: {str(e)}"})

    except Exception as e:
        logger.error(f"Unexpected error: {e}")
        return _response(500, {"error": "Internal server error"})
