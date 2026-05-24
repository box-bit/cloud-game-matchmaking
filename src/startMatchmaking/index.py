import json
import os
import time
import uuid
import boto3
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

dynamo = boto3.resource("dynamodb")

CORS_HEADERS = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Authorization,Content-Type",
    "Access-Control-Allow-Methods": "POST,OPTIONS",
}


def _response(status, body):
    return {
        "statusCode": status,
        "headers": CORS_HEADERS,
        "body": json.dumps(body),
    }


def handler(event, context):
    try:
        claims = event["requestContext"]["authorizer"]["claims"]
        user_id = claims["sub"]
        logger.info(f"Matchmaking request from UserId: {user_id}")

        player_table = dynamo.Table(os.environ["PLAYER_TABLE"])
        response = player_table.get_item(Key={"UserId": user_id})

        if "Item" not in response:
            logger.warning(f"No profile found for UserId: {user_id}")
            return _response(404, {"error": "Player profile not found"})

        player = response["Item"]
        elo = int(player["ELO"])
        logger.info(f"Player {user_id} has ELO {elo}")

        ticket_id = str(uuid.uuid4())
        now = int(time.time())

        tickets_table = dynamo.Table(os.environ["TICKETS_TABLE"])
        tickets_table.put_item(
            Item={
                "TicketId": ticket_id,
                "UserId": user_id,
                "Status": "SEARCHING",
                "ELO": elo,
                "CreatedAt": now,
                "TTL": now + 3600,
            }
        )
        logger.info(f"Ticket created: {ticket_id}")

        return _response(
            200,
            {
                "message": "Matchmaking started",
                "userId": user_id,
                "elo": elo,
                "ticketId": ticket_id,
                "status": "SEARCHING",
            },
        )

    except KeyError as e:
        logger.error(f"Missing expected field: {e}")
        return _response(400, {"error": f"Missing field: {str(e)}"})

    except Exception as e:
        logger.error(f"Unexpected error: {e}")
        return _response(500, {"error": "Internal server error"})
