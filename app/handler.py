"""Lambda handler for the reference API endpoint.

Returns request metadata as JSON. The function itself is intentionally
simple — the pipeline is the point, not the application logic.
"""

import json
import logging
from datetime import UTC, datetime
from typing import Any

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

# Version is set at deploy time via the FUNCTION_VERSION environment variable.
# Defaults to "local" so the function runs without modification in unit tests.
import os

FUNCTION_VERSION = os.getenv("FUNCTION_VERSION", "local")


def _response(status_code: int, body: dict[str, Any]) -> dict[str, Any]:
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "X-Function-Version": FUNCTION_VERSION,
        },
        "body": json.dumps(body),
    }


def handler(event: dict[str, Any], context: object) -> dict[str, Any]:
    """API Gateway proxy integration handler.

    Args:
        event:   API Gateway proxy event dict.
        context: Lambda context object (not used).

    Returns:
        API Gateway proxy response dict with statusCode, headers, and body.
    """
    path = event.get("path", "/")
    method = event.get("httpMethod", "GET")

    logger.info("request: method=%s path=%s", method, path)

    return _response(
        200,
        {
            "message": "ok",
            "path": path,
            "method": method,
            "version": FUNCTION_VERSION,
            "timestamp": datetime.now(UTC).isoformat(),
        },
    )
