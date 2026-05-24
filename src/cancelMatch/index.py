import json
import os
import boto3
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

dynamo = boto3.resource("dynamodb")

CANCELLABLE_STATUSES = {"SEARCHING"}

CORS_HEADERS = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Authorization,Content-Type",
    "Access-Control-Allow-Methods": "DELETE,OPTIONS",
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
        ticket_id = event["pathParameters"]["ticketId"]

        tickets_table = dynamo.Table(os.environ["TICKETS_TABLE"])
        response = tickets_table.get_item(Key={"TicketId": ticket_id})

        if "Item" not in response:
            return _response(404, {"error": "Ticket not found"})

        ticket = response["Item"]

        if ticket.get("UserId") != user_id:
            return _response(403, {"error": "Forbidden"})

        current_status = ticket.get("Status", "")
        if current_status not in CANCELLABLE_STATUSES:
            return _response(
                409,
                {"error": f"Cannot cancel ticket with status: {current_status}"},
            )

        tickets_table.update_item(
            Key={"TicketId": ticket_id},
            UpdateExpression="SET #s = :s",
            ExpressionAttributeNames={"#s": "Status"},
            ExpressionAttributeValues={":s": "CANCELLED"},
        )
        logger.info(f"Ticket cancelled: {ticket_id}")

        return _response(
            200, {"message": "Matchmaking cancelled", "ticketId": ticket_id}
        )

    except KeyError as e:
        return _response(400, {"error": f"Missing field: {str(e)}"})

    except Exception as e:
        logger.error(f"Unexpected error: {e}")
        return _response(500, {"error": "Internal server error"})
