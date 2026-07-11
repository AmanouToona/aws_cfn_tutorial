import json
import importlib
import os
from datetime import datetime, timedelta, timezone

RATE_LIMIT_TABLE_NAME = os.environ.get("RATE_LIMIT_TABLE_NAME", "")

_dynamodb = importlib.import_module("boto3").resource("dynamodb")


def build_response(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
        },
        "body": json.dumps(body),
    }


def get_rate_limit_context(event):
    request_context = event.get("requestContext") or {}
    authorizer = request_context.get("authorizer") or {}
    claims = authorizer.get("claims") or {}
    user_sub = claims.get("sub")

    if user_sub:
        return ("auth", user_sub, 100)

    identity = request_context.get("identity") or {}
    source_ip = identity.get("sourceIp") or "unknown"
    return ("anon", source_ip, 10)


def increment_rate_limit(counter_type, identifier):
    if not RATE_LIMIT_TABLE_NAME:
        raise RuntimeError("RATE_LIMIT_TABLE_NAME is not set")

    now = datetime.now(timezone.utc)
    window = now.strftime("%Y%m%d%H%M")
    expires_at = int((now + timedelta(minutes=2)).timestamp())
    rate_key = f"{counter_type}#{identifier}#{window}"

    table = _dynamodb.Table(RATE_LIMIT_TABLE_NAME)
    result = table.update_item(
        Key={"rate_key": rate_key},
        UpdateExpression=(
            "SET request_count = if_not_exists(request_count, :zero) + :one, "
            "#ttl = :ttl"
        ),
        ExpressionAttributeNames={
            "#ttl": "ttl",
        },
        ExpressionAttributeValues={
            ":zero": 0,
            ":one": 1,
            ":ttl": expires_at,
        },
        ReturnValues="UPDATED_NEW",
    )
    return int(result["Attributes"]["request_count"])


def lambda_handler(event, context):
    try:
        counter_type, identifier, limit = get_rate_limit_context(event)
        request_count = increment_rate_limit(counter_type, identifier)
    except Exception as error:
        return build_response(
            500,
            {
                "message": "failed to evaluate rate limit",
                "error": str(error),
            },
        )

    if request_count > limit:
        return build_response(
            429,
            {
                "message": "rate limit exceeded",
                "limit": limit,
                "request_count": request_count,
                "identifier_type": counter_type,
            },
        )

    path = event.get("path", "")
    message = "secret" if path.endswith("/secret") else "hello"

    return build_response(
        200,
        {
            "message": message,
            "rate_limit": {
                "identifier_type": counter_type,
                "limit": limit,
                "request_count": request_count,
            },
        },
    )