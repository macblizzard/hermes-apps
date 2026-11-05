from fastapi.testclient import TestClient

from hermes_bridge.app import WS_TICKET_TTL_SECONDS, create_app


def client() -> TestClient:
    # TestClient's default client host is "testclient", so mint codes from loopback.
    return TestClient(create_app(), client=("127.0.0.1", 50000))


def test_health():
    r = client().get("/v1/health")
    assert r.status_code == 200
    assert r.json()["status"] == "ok"
    assert r.json()["protocol_version"] == 1


def test_pairing_happy_path():
    c = client()
    start = c.post("/v1/pair/start")
    assert start.status_code == 200
    code = start.json()["code"]
    assert len(code) == 8

    claim = c.post(
        "/v1/pair/claim",
        json={"code": code, "public_key": "A" * 44, "device_name": "iPhone", "platform": "ios"},
    )
    assert claim.status_code == 200, claim.text
    device_id = claim.json()["device_id"]
    refresh = claim.json()["refresh_token"]

    tok = c.post("/v1/token", json={"device_id": device_id, "refresh_token": refresh})
    assert tok.status_code == 200
    assert tok.json()["ws_ticket"]
    assert tok.json()["expires_in"] > 0

    # the code is single use
    again = c.post(
        "/v1/pair/claim",
        json={"code": code, "public_key": "A" * 44, "device_name": "x", "platform": "ios"},
    )
    assert again.status_code == 401


def test_bad_refresh_token_is_refused():
    c = client()
    code = c.post("/v1/pair/start").json()["code"]
    claim = c.post(
        "/v1/pair/claim",
        json={"code": code, "public_key": "B" * 44, "device_name": "Mac", "platform": "macos"},
    ).json()
    bad = c.post("/v1/token", json={"device_id": claim["device_id"], "refresh_token": "nope"})
    assert bad.status_code == 401


def test_revoked_device_cannot_mint_tokens():
    c = client()
    code = c.post("/v1/pair/start").json()["code"]
    claim = c.post(
        "/v1/pair/claim",
        json={"code": code, "public_key": "C" * 44, "device_name": "Mac", "platform": "macos"},
    ).json()
    assert c.delete(f"/v1/devices/{claim['device_id']}").status_code == 200
    tok = c.post(
        "/v1/token", json={"device_id": claim["device_id"], "refresh_token": claim["refresh_token"]}
    )
    assert tok.status_code == 401


def test_pairing_code_is_host_only():
    c = TestClient(create_app(), client=("10.0.0.9", 5000))
    assert c.post("/v1/pair/start").status_code == 403


def test_ws_ticket_ttl_is_short():
    assert WS_TICKET_TTL_SECONDS == 30
