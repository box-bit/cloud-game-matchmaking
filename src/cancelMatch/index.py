import json
import os
import boto3
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

dynamo = boto3.resource("dynamodb")

CANCELLABLE_STATUSES = {"SEARCHING"}


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

        current_status = ticket.get("Status", "")
        if current_status not in CANCELLABLE_STATUSES:
            return {
                "statusCode": 409,
                "body": json.dumps(
                    {"error": f"Cannot cancel ticket with status: {current_status}"}
                ),
            }

        tickets_table.update_item(
            Key={"TicketId": ticket_id},
            UpdateExpression="SET #s = :s",
            ExpressionAttributeNames={"#s": "Status"},
            ExpressionAttributeValues={":s": "CANCELLED"},
        )
        logger.info(f"Ticket cancelled: {ticket_id}")

        return {
            "statusCode": 200,
            "body": json.dumps(
                {"message": "Matchmaking cancelled", "ticketId": ticket_id}
            ),
        }

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
