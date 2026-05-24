import json
import os
import re
import boto3
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

dynamo = boto3.resource("dynamodb")
cognito = boto3.client("cognito-idp")

CORS_HEADERS = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Authorization,Content-Type",
    "Access-Control-Allow-Methods": "POST,OPTIONS",
}

EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


def _response(status, body):
    return {
        "statusCode": status,
        "headers": CORS_HEADERS,
        "body": json.dumps(body),
    }


def handler(event, context):
    try:
        body = json.loads(event.get("body") or "{}")
        email = (body.get("email") or "").strip().lower()
        username = (body.get("username") or "").strip()
        password = body.get("password") or ""
        elo_raw = body.get("elo")

        if not EMAIL_RE.match(email):
            return _response(400, {"error": "Invalid email"})
        if not username or len(username) > 40:
            return _response(400, {"error": "Username must be 1–40 characters"})
        if len(password) < 8:
            return _response(400, {"error": "Password must be at least 8 characters"})
        try:
            elo = int(elo_raw)
        except (TypeError, ValueError):
            return _response(400, {"error": "ELO must be an integer"})
        if not 0 <= elo <= 4000:
            return _response(400, {"error": "ELO must be between 0 and 4000"})

        client_id = os.environ["USER_POOL_CLIENT_ID"]
        pool_id = os.environ["USER_POOL_ID"]

        # 1. Cognito sign-up
        try:
            sign_up = cognito.sign_up(
                ClientId=client_id,
                Username=email,
                Password=password,
                UserAttributes=[{"Name": "email", "Value": email}],
            )
        except cognito.exceptions.UsernameExistsException:
            return _response(409, {"error": "An account with that email already exists"})
        except cognito.exceptions.InvalidPasswordException as e:
            return _response(400, {"error": f"Invalid password: {e.response['Error']['Message']}"})

        user_sub = sign_up["UserSub"]

        # 2. Auto-confirm — skip email verification for this demo
        cognito.admin_confirm_sign_up(UserPoolId=pool_id, Username=email)

        # 3. Seed PlayerProfiles with the user-supplied ELO + username
        dynamo.Table(os.environ["PLAYER_TABLE"]).put_item(
            Item={
                "UserId": user_sub,
                "Username": username,
                "ELO": elo,
                "Wins": 0,
                "Losses": 0,
            }
        )
        logger.info(f"Registered {email} (sub={user_sub}) with ELO {elo}")

        return _response(
            201,
            {
                "userId": user_sub,
                "email": email,
                "username": username,
                "elo": elo,
            },
        )

    except KeyError as e:
        logger.error(f"Missing expected field: {e}")
        return _response(400, {"error": f"Missing field: {str(e)}"})

    except Exception as e:
        logger.exception("Unexpected error during registration")
        return _response(500, {"error": "Internal server error"})
