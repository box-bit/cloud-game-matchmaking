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


def handler(event, context):
    try:
        claims = event["requestContext"]["authorizer"]["claims"]
        user_id = claims["sub"]
        email = claims.get("email", "")

        player_table = dynamo.Table(os.environ["PLAYER_TABLE"])
        response = player_table.get_item(Key={"UserId": user_id})

        if "Item" not in response:
            return _response(404, {"error": "Player profile not found"})

        player = response["Item"]
        return _response(
            200,
            {
                "userId": user_id,
                "email": email,
                "username": player.get("Username", ""),
                "elo": int(player.get("ELO", 0)),
                "wins": int(player.get("Wins", 0)),
                "losses": int(player.get("Losses", 0)),
            },
        )

    except KeyError as e:
        logger.error(f"Missing expected field: {e}")
        return _response(400, {"error": f"Missing field: {str(e)}"})

    except Exception as e:
        logger.error(f"Unexpected error: {e}")
        return _response(500, {"error": "Internal server error"})
