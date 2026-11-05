"""Bridge HTTP surface (M0 skeleton).

Implemented here: health, pairing, device registry, token exchange.
Owned next by the bridge agent: the `/v1/ws` JSON-RPC proxy and APNs push.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import os
import secrets
import time
from dataclasses import dataclass, field
from typing import Dict, Optional

from fastapi import FastAPI, HTTPException, Request
from pydantic import BaseModel, Field

PAIRING_CODE_TTL_SECONDS = 120
ACCESS_TOKEN_TTL_SECONDS = 15 * 60
WS_TICKET_TTL_SECONDS = 30
PROTOCOL_VERSION = 1


@dataclass
class Device:
    device_id: str
    name: str
    platform: str
    public_key: str
    refresh_token_hash: str
    created_at: float
    last_seen_at: float
    revoked: bool = False


@dataclass
class BridgeState:
    devices: Dict[str, Device] = field(default_factory=dict)
    pairing_codes: Dict[str, float] = field(default_factory=dict)  # code -> expires_at
    ws_tickets: Dict[str, tuple[float, str]] = field(default_factory=dict)

    def hashed(self, token: str) -> str:
        return hashlib.sha256(token.encode()).hexdigest()


class PairStartResponse(BaseModel):
    code: str
    expires_at: float
    host: str
    protocol_version: int


class PairClaimRequest(BaseModel):
    code: str = Field(min_length=4, max_length=64)
    public_key: str = Field(min_length=32, max_length=512)
    device_name: str = Field(default="device", max_length=80)
    platform: str = Field(default="unknown", max_length=16)


class PairClaimResponse(BaseModel):
    device_id: str
    refresh_token: str
    protocol_version: int


class TokenRequest(BaseModel):
    refresh_token: str
    device_id: str


class TokenResponse(BaseModel):
    access_token: str
    ws_ticket: str
    expires_in: int


def create_app() -> FastAPI:
    app = FastAPI(title="hermes-bridge", version="0.1.0")
    state = BridgeState()

    @app.get("/v1/health")
    def health() -> dict:
        return {
            "status": "ok",
            "protocol_version": PROTOCOL_VERSION,
            "devices": len([d for d in state.devices.values() if not d.revoked]),
        }

    @app.post("/v1/pair/start", response_model=PairStartResponse)
    def pair_start(request: Request) -> PairStartResponse:
        # Only a caller already on the host (tailnet-authenticated, loopback) may mint a code.
        client = request.client.host if request.client else ""
        if client not in {"127.0.0.1", "::1"}:
            raise HTTPException(status_code=403, detail="pairing codes are minted on the host only")
        code = f"{secrets.randbelow(10**8):08d}"
        expires = time.time() + PAIRING_CODE_TTL_SECONDS
        state.pairing_codes[code] = expires
        return PairStartResponse(
            code=code,
            expires_at=expires,
            host=os.environ.get("HERMES_BRIDGE_PUBLIC_HOST", "hermes.corvus-vibes.ts.net"),
            protocol_version=PROTOCOL_VERSION,
        )

    @app.post("/v1/pair/claim", response_model=PairClaimResponse)
    def pair_claim(body: PairClaimRequest) -> PairClaimResponse:
        expires = state.pairing_codes.pop(body.code, None)
        if expires is None or expires < time.time():
            raise HTTPException(status_code=401, detail="pairing code invalid or expired")
        device_id = base64.urlsafe_b64encode(secrets.token_bytes(12)).decode().rstrip("=")
        refresh = secrets.token_urlsafe(32)
        now = time.time()
        state.devices[device_id] = Device(
            device_id=device_id,
            name=body.device_name,
            platform=body.platform,
            public_key=body.public_key,
            refresh_token_hash=state.hashed(refresh),
            created_at=now,
            last_seen_at=now,
        )
        return PairClaimResponse(
            device_id=device_id, refresh_token=refresh, protocol_version=PROTOCOL_VERSION
        )

    @app.post("/v1/token", response_model=TokenResponse)
    def token(body: TokenRequest) -> TokenResponse:
        device = state.devices.get(body.device_id)
        if device is None or device.revoked:
            raise HTTPException(status_code=401, detail="unknown device")
        if not hmac.compare_digest(device.refresh_token_hash, state.hashed(body.refresh_token)):
            raise HTTPException(status_code=401, detail="bad refresh token")
        ticket = secrets.token_urlsafe(32)
        state.ws_tickets[ticket] = (time.time() + WS_TICKET_TTL_SECONDS, device.device_id)
        device.last_seen_at = time.time()
        return TokenResponse(
            access_token=secrets.token_urlsafe(32),
            ws_ticket=ticket,
            expires_in=ACCESS_TOKEN_TTL_SECONDS,
        )

    @app.get("/v1/devices")
    def devices() -> list[dict]:
        return [
            {
                "device_id": d.device_id,
                "name": d.name,
                "platform": d.platform,
                "created_at": d.created_at,
                "last_seen_at": d.last_seen_at,
                "revoked": d.revoked,
            }
            for d in state.devices.values()
        ]

    @app.delete("/v1/devices/{device_id}")
    def revoke(device_id: str) -> dict:
        device = state.devices.get(device_id)
        if device is None:
            raise HTTPException(status_code=404, detail="unknown device")
        device.revoked = True
        return {"revoked": device_id}

    return app


app = create_app()
