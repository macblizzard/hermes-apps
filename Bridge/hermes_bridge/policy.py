"""What the bridge is willing to carry, and nothing more.

The allow-list is the whole security boundary between a paired phone and a Hermes
host that can run shell commands, edit files and read a vault. It is deliberately
a static frozenset: adding a method is a code change with a test, not a config
flag.

Two directions are policed separately:

``CLIENT_METHODS``
    requests the app may send to the gateway. This is the session/prompt surface
    the UI actually needs. ``shell.exec``, ``cli.exec``, ``config.set``,
    ``vault.*``, ``tools.configure`` and friends are *not* on it: a compromised
    client must not be able to escalate through the bridge.

``SERVER_REQUEST_METHODS``
    requests the gateway may send to the app. Everything here is a human
    decision that must reach a screen (an approval, a clarify, a sudo prompt, a
    secret, a vault code, a terminal read). Anything else is answered ``-32601``
    by the bridge so the agent fails fast instead of waiting out a timeout.
"""

from __future__ import annotations

import re
from typing import TypeGuard

#: Requests the app may send. Read-only browsing + the conversation loop.
CLIENT_METHODS = frozenset(
    {
        # liveness / handshake
        "ping",
        "client.capabilities",
        "gateway.capabilities",
        # sessions
        "session.list",
        "session.active_list",
        "session.most_recent",
        "session.create",
        "session.resume",
        "session.info",
        "session.status",
        "session.history",
        "session.events.since",
        "session.events.stats",
        "session.title",
        "session.close",
        "session.archive",
        "session.delete",
        "session.interrupt",
        "session.steer",
        "session.undo",
        "session.branch",
        "session.compress",
        "session.usage",
        "session.control",
        "session.control.read",
        # prompts
        "prompt.submit",
        "prompt.cancel",
        "prompt.background",
        "prompt.btw",
        "prompt.receipt",
        # answers the app gives as *requests* (not responses) in some flows
        "approval.pending",
        "approval.received",
        "approval.respond",
        "clarify.respond",
        "connection.respond",
        # composer / discovery
        "complete.slash",
        "complete.path",
        "commands.catalog",
        "model.options",
        "tools.list",
        "toolsets.list",
        "projects.list",
        "agents.list",
        "subagent.list",
    }
)

#: Requests the gateway may send to the app. These must reach the user.
SERVER_REQUEST_METHODS = frozenset(
    {
        "approval",
        "clarify",
        "sudo",
        "secret",
        "vault.code",
        "terminal.read",
    }
)

_METHOD_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_.-]{0,63}$")


def is_valid_method_name(method: object) -> TypeGuard[str]:
    return isinstance(method, str) and bool(_METHOD_RE.match(method))


def build_client_allow_list(extra: frozenset[str] | None = None) -> frozenset[str]:
    """Return the effective allow-list, validating operator additions."""
    allowed = set(CLIENT_METHODS)
    for method in extra or frozenset():
        if not is_valid_method_name(method):
            raise ValueError(f"invalid method name in bridge allow-list: {method!r}")
        allowed.add(method)
    return frozenset(allowed)


def is_client_method_allowed(method: object, extra: frozenset[str] | None = None) -> bool:
    return method in build_client_allow_list(extra)


def is_server_request_allowed(method: object) -> bool:
    return method in SERVER_REQUEST_METHODS
