"""Unit tests for the Lambda handler.

No AWS SDK calls, no mocking required — the handler is pure input/output.
"""

import json

import pytest

from handler import _response, handler


def _event(path: str = "/", method: str = "GET") -> dict:
    return {"path": path, "httpMethod": method}


class TestResponse:
    def test_status_code(self) -> None:
        r = _response(200, {"ok": True})
        assert r["statusCode"] == 200

    def test_body_is_json_string(self) -> None:
        r = _response(200, {"key": "value"})
        parsed = json.loads(r["body"])
        assert parsed["key"] == "value"

    def test_content_type_header(self) -> None:
        r = _response(200, {})
        assert r["headers"]["Content-Type"] == "application/json"


class TestHandler:
    def test_returns_200(self) -> None:
        response = handler(_event(), context=object())
        assert response["statusCode"] == 200

    def test_body_is_valid_json(self) -> None:
        response = handler(_event(), context=object())
        body = json.loads(response["body"])
        assert isinstance(body, dict)

    def test_message_field_present(self) -> None:
        response = handler(_event(), context=object())
        body = json.loads(response["body"])
        assert body["message"] == "ok"

    def test_path_echoed_in_body(self) -> None:
        response = handler(_event(path="/foo/bar"), context=object())
        body = json.loads(response["body"])
        assert body["path"] == "/foo/bar"

    def test_method_echoed_in_body(self) -> None:
        response = handler(_event(method="POST"), context=object())
        body = json.loads(response["body"])
        assert body["method"] == "POST"

    def test_timestamp_field_present(self) -> None:
        response = handler(_event(), context=object())
        body = json.loads(response["body"])
        assert "timestamp" in body
        # ISO-8601 strings contain "T"
        assert "T" in body["timestamp"]

    def test_version_field_present(self) -> None:
        response = handler(_event(), context=object())
        body = json.loads(response["body"])
        assert "version" in body

    def test_missing_path_defaults_gracefully(self) -> None:
        response = handler({}, context=object())
        assert response["statusCode"] == 200
        body = json.loads(response["body"])
        assert body["path"] == "/"

    def test_missing_method_defaults_gracefully(self) -> None:
        response = handler({}, context=object())
        body = json.loads(response["body"])
        assert body["method"] == "GET"
