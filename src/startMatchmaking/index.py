import json
import os
import boto3
import logging

# Logger is visible in CloudWatch — your main debugging tool
logger = logging.getLogger()
logger.setLevel(logging.INFO)

dynamo = boto3.resource("dynamodb")


def handler(event, context):
    try:
        # 1. Extract UserId from the Cognito JWT
        #    API Gateway decodes the token and injects claims automatically
        claims = event["requestContext"]["authorizer"]["claims"]
        user_id = claims["sub"]
        logger.info(f"Matchmaking request from UserId: {user_id}")

        # 2. Read player profile from DynamoDB
        table = dynamo.Table(os.environ["PLAYER_TABLE"])
        response = table.get_item(Key={"UserId": user_id})

        if "Item" not in response:
            logger.warning(f"No profile found for UserId: {user_id}")
            return {
                "statusCode": 404,
                "body": json.dumps({"error": "Player profile not found"}),
            }

        player = response["Item"]
        elo = int(player["ELO"])
        logger.info(f"Player {user_id} has ELO {elo}")

        # 3. TODO Phase 3: Call FlexMatch here
        #    For now return a mock ticket to confirm the pipeline works
        mock_ticket_id = f"mock-ticket-{context.aws_request_id}"

        return {
            "statusCode": 200,
            "body": json.dumps(
                {
                    "message": "Matchmaking request received",
                    "userId": user_id,
                    "elo": elo,
                    "ticketId": mock_ticket_id,
                }
            ),
        }

    except KeyError as e:
        logger.error(f"Missing expected field: {e}")
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
