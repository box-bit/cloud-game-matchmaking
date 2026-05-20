import json
import os
import boto3
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

dynamo = boto3.resource("dynamodb")


def handler(event, context):
    try:
        claims = event["requestContext"]["authorizer"]["claims"]
        user_id = claims["sub"]
        ticket_id = event["pathParameters"]["ticketId"]

        tickets_table = dynamo.Table(os.environ["TICKETS_TABLE"])
        response = tickets_table.get_item(Key={"TicketId": ticket_id})

        if "Item" not in response:
            return {
                "statusCode": 404,
                "body": json.dumps({"error": "Ticket not found"}),
            }

        ticket = response["Item"]

        if ticket.get("UserId") != user_id:
            return {
                "statusCode": 403,
                "body": json.dumps({"error": "Forbidden"}),
            }

        body = {
            "ticketId": ticket_id,
            "status": ticket.get("Status"),
            "userId": ticket.get("UserId"),
            "elo": int(ticket.get("ELO", 0)),
            "matchedPlayers": ticket.get("MatchedPlayers", []),
        }

        if ticket.get("ServerIp"):
            body["serverIp"] = ticket["ServerIp"]
            body["serverPort"] = int(ticket.get("ServerPort", 26000))

        return {"statusCode": 200, "body": json.dumps(body)}

    except KeyError as e:
        return {
            "statusCode": 400,
            "body": json.dumps({"error": f"Missing field: {str(e)}"}),
        }

    except Exception as e:
        logger.error(f"Unexpected error: {e}")
        return {
            "statusCode": 500,
            "body": json.dumps({"error": "Internal server error"}),
        }
