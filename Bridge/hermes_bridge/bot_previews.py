"""The newest message of each bot's conversation, for the bot list's third line.

Why this lives in the bridge and not in the gateway call the app already makes: the gateway's
``session.list`` preview is the **first eligible user message** of a session (it is a title
stand-in — ``hermes_state_common._sql_preview_raw``), so a row built from it shows what was asked
at the beginning of the conversation, forever. The newest message, whoever wrote it, is one
indexed query against the profile's own ``state.db`` — and the bridge is the one process that can
answer for *every* bot in a single request instead of one transcript per bot.

Contract::

    GET /v1/bots/previews
    -> {"previews": {"<profile>": {"text": "...", "role": "user"|"assistant", "at": 1762300000.0}}}

A profile with no conversation yet is simply absent: an empty third line is honest, an invented
one is not. The answer is cached briefly because it is a *decoration* — a row must never wait on
another profile's database.
"""
from __future__ import annotations

import os
import re
import sqlite3
import time
from pathlib import Path
from typing import Optional

from fastapi import APIRouter, Header

from .device_auth import require_device

#: Long enough that a burst of list refreshes is one read, short enough that a reply shows up
#: while the user is still looking at the list.
CACHE_SECONDS = 15.0

#: A bot row has one line. Anything past this is clipped by the client anyway.
MAX_CHARS = 200


def _profiles_root() -> Path:
    """Where the bots live, whether this process is given the install home or a profile home.

    ``HERMES_HOME`` can be either: the install home (``~/.hermes``, so bots are ``profiles/*``) or
    a running profile (``~/.hermes/profiles/cody``), in which case the other bots are its siblings.
    Guessing wrong here means an endpoint that quietly answers nothing, which is worse than one
    that is slow, so both shapes are checked against the filesystem.
    """
    candidates: list[Path] = []
    home = os.environ.get("HERMES_HOME")
    if home:
        base = Path(home)
        candidates.append(base / "profiles")
        if base.parent.name == "profiles":
            candidates.append(base.parent)
    candidates.append(Path.home() / ".hermes" / "profiles")
    for candidate in candidates:
        if candidate.is_dir():
            return candidate
    return candidates[-1]


_MARKUP = re.compile(r"\*\*|__|`+")
_LEADING = re.compile(r"^(#{1,6}\s+|>\s+|[-*+]\s+)")


def _first_line(raw: Optional[str]) -> Optional[str]:
    if not raw:
        return None
    for line in raw.splitlines():
        line = line.strip()
        if line:
            # A row is plain text: the reply's own emphasis marks and list bullets would show up
            # literally. Only marks that cannot be part of a word are removed — `snake_case` and
            # `*args` inside a preview must stay as typed.
            line = _MARKUP.sub("", line)
            line = _LEADING.sub("", line)
            return line.strip()[:MAX_CHARS]
    return None


def _newest_session(conn: sqlite3.Connection) -> Optional[str]:
    """The most recently active session **that has a message worth previewing**.

    A profile keeps placeholder sessions (`local-…`) with no turns in them, and they are often the
    most recent rows — ordering by activity alone picked one of those and the row lost its third
    line. The `EXISTS` is an indexed lookup per session, so this stays cheap.
    """
    eligible = (
        "EXISTS (SELECT 1 FROM messages m WHERE m.session_id = s.id "
        "AND m.role IN ('user', 'assistant') AND m.content IS NOT NULL "
        "AND TRIM(m.content) <> '')"
    )
    try:
        row = conn.execute(
            f"SELECT s.id FROM sessions s WHERE {eligible} "
            "ORDER BY COALESCE(s.last_activity_at, s.started_at, 0) DESC LIMIT 1"
        ).fetchone()
    except sqlite3.Error:
        row = conn.execute(
            f"SELECT s.id FROM sessions s WHERE {eligible} "
            "ORDER BY COALESCE(s.started_at, 0) DESC LIMIT 1"
        ).fetchone()
    return str(row[0]) if row else None


def _last_message(db_path: Path, session_id: Optional[str]) -> Optional[dict]:
    """The newest user/assistant message, preferring the bot's known conversation."""
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=2.0)
    try:
        session = session_id
        if session:
            exists = conn.execute("SELECT 1 FROM sessions WHERE id = ?", (session,)).fetchone()
            if not exists:
                session = None
        if not session:
            session = _newest_session(conn)
        if not session:
            return None
        row = conn.execute(
            "SELECT role, content, timestamp FROM messages "
            "WHERE session_id = ? AND role IN ('user', 'assistant') "
            "AND content IS NOT NULL AND TRIM(content) <> '' "
            "ORDER BY timestamp DESC, id DESC LIMIT 1",
            (session,),
        ).fetchone()
        if not row:
            return None
        text = _first_line(row[1])
        if not text:
            return None
        return {"text": text, "role": str(row[0]), "at": row[2]}
    finally:
        conn.close()


def create_bot_previews_router(runtime) -> APIRouter:
    router = APIRouter(prefix='/v1/bots', tags=['bot-previews'])
    #: profile -> (expires_at, payload)
    cache: dict[str, tuple[float, dict]] = {}
    root = _profiles_root()

    def authenticate(authorization) -> str:
        return require_device(runtime, authorization)

    def preview_for(profile: str) -> Optional[dict]:
        now = time.monotonic()
        cached = cache.get(profile)
        if cached and cached[0] > now:
            return cached[1]
        db_path = root / profile / 'state.db'
        if not db_path.is_file():
            return None
        try:
            with_stored = None
            try:
                with_stored = runtime.registry.get_bot_session(profile)
            except Exception:
                with_stored = None
            payload = _last_message(db_path, with_stored)
        except Exception:
            # A profile whose database is being written, or is older than this schema, loses its
            # third line and nothing else.
            return None
        if payload is None:
            return None
        cache[profile] = (now + CACHE_SECONDS, payload)
        return payload

    @router.get('/previews')
    def list_previews(authorization: Optional[str] = Header(default=None)) -> dict:
        device_id = authenticate(authorization)
        previews: dict[str, dict] = {}
        try:
            names = sorted(p.name for p in root.iterdir() if (p / 'state.db').is_file())
        except OSError:
            names = []
        for profile in names:
            payload = preview_for(profile)
            if payload:
                previews[profile] = payload
        # `emit` takes a fixed set of keywords and a fixed set of event names; either miss raises,
        # and a 500 here would cost every bot its third line for the sake of a log line.
        runtime.audit.emit('http', device_id=device_id, method='GET',
                           path='/v1/bots/previews', outcome='ok')
        return {'previews': previews}

    return router
