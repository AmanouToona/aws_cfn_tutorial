import json

def lambda_handler(event, context):
    path = event.get("path", "")
    message = "secret" if path.endswith("/secret") else "hello"

    return {
        "statusCode": 200,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*"
        },
        "body": json.dumps({"message": message})
    }