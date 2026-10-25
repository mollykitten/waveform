#!/usr/bin/env python3
"""Forward explicit ACP worker completion markers to a coordinator session."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional, Protocol


MARKERS = ("SUPERSET_WORKER_DONE", "SUPERSET_WORKER_BLOCKED")
UNSUCCESSFUL_TURN_STATUSES = {"failed", "interrupted", "cancelled", "canceled", "aborted"}
DEFAULT_STATE = Path.home() / ".local/state/superset/worker-notifier-state.json"


class NotifierError(Exception):
    pass


class SourceUnavailable(NotifierError):
    pass


class SessionNotFound(NotifierError):
    pass


class SourceTerminal(NotifierError):
    pass


class Transport(Protocol):
    def list_sessions(self, workspace: str) -> list[dict[str, Any]]: ...

    def read_session(self, workspace: str, session: str, before: Optional[str]) -> dict[str, Any]: ...

    def send(self, workspace: str, session: str, message: str) -> None: ...


class SupersetTransport:
    def __init__(self, local: bool = True) -> None:
        self.local = local

    def _run(self, args: list[str]) -> Any:
        result = subprocess.run(args, check=True, capture_output=True, text=True, timeout=30)
        try:
            data = json.loads(result.stdout)
        except json.JSONDecodeError as exc:
            raise NotifierError("Superset returned malformed JSON") from exc
        if not isinstance(data, (dict, list)):
            raise NotifierError("Superset JSON response must be an object or array")
        return data

    def _base(self, action: str, workspace: str) -> list[str]:
        args = ["superset", "sessions", action, "--workspace", workspace]
        if self.local:
            args.append("--local")
        args.append("--json")
        return args

    def list_sessions(self, workspace: str) -> list[dict[str, Any]]:
        response = self._run(self._base("list", workspace) + ["--limit", "200"])
        if not isinstance(response, list) or not all(isinstance(row, dict) for row in response):
            raise NotifierError("Superset sessions list must be an array of sessions")
        return response

    def read_session(self, workspace: str, session: str, before: Optional[str]) -> dict[str, Any]:
        args = self._base("read", workspace) + ["--session", session, "--limit", "100"]
        if before:
            args += ["--before", before]
        try:
            return self._run(args)
        except subprocess.CalledProcessError as exc:
            detail = (exc.stderr or "") + (exc.stdout or "")
            if (f"Chat session {session} not found in workspace {workspace}" in detail):
                raise SessionNotFound(f"direct session read reports {session} missing") from exc
            raise

    def send(self, workspace: str, session: str, message: str) -> None:
        args = self._base("send", workspace) + ["--session", session, "--prompt", message]
        subprocess.run(args, check=True, capture_output=True, text=True, timeout=30)


@dataclass(frozen=True)
class Endpoint:
    workspace: str
    session: str


@dataclass(frozen=True)
class Config:
    source: Endpoint
    target: Endpoint
    task: str
    since_ms: int


def load_config(path: Path) -> Config:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise NotifierError(f"cannot read config JSON: {exc}") from exc
    if not isinstance(raw, dict):
        raise NotifierError("config must be a JSON object")
    try:
        source = _endpoint(raw["source"])
        target = _endpoint(raw["target"])
        task = raw["task"]
        since_ms = raw["since_ms"]
    except (KeyError, TypeError, ValueError) as exc:
        raise NotifierError("config requires source and target workspace/session IDs") from exc
    if source == target:
        raise NotifierError("source and target must be different sessions")
    if not isinstance(task, str) or not task.strip():
        raise NotifierError("config task must be a nonempty string")
    if isinstance(since_ms, bool) or not isinstance(since_ms, int) or since_ms < 0:
        raise NotifierError("config since_ms must be a nonnegative integer")
    return Config(source, target, task.strip(), since_ms)


def _endpoint(value: Any) -> Endpoint:
    if not isinstance(value, dict):
        raise ValueError("endpoint must be an object")
    workspace, session = value.get("workspace"), value.get("session")
    if not all(isinstance(item, str) and item.strip() for item in (workspace, session)):
        raise ValueError("endpoint IDs must be nonempty strings")
    return Endpoint(workspace.strip(), session.strip())


def _session_rows(response: Any) -> list[dict[str, Any]]:
    if isinstance(response, list):
        return [row for row in response if isinstance(row, dict)]
    if isinstance(response, dict):
        rows = response.get("sessions", response.get("items", []))
        return [row for row in rows if isinstance(row, dict)] if isinstance(rows, list) else []
    return []


def _session_id(row: dict[str, Any]) -> Optional[str]:
    value = row.get("sessionId", row.get("id"))
    return value if isinstance(value, str) else None


def session_observation(response: Any, wanted: str) -> str:
    """Read lifecycle metadata; omission from the capped list is unknown."""
    rows = _session_rows(response)
    row = next((item for item in rows if _session_id(item) == wanted), None)
    if row is None:
        return "unknown"
    status = str(row.get("status", row.get("state", ""))).lower()
    # `live` and `status` describe the ACP session. A terminal worker process
    # alone does not close it; only an explicit non-live/terminal row or a
    # successful list result that omits the configured session does.
    if row.get("live") is True or status in {"running", "queued", "starting"}:
        return "live"
    if row.get("live") is False or status in {"stopped", "completed", "failed", "terminated", "exited"}:
        return "terminal"
    return "live"


def _envelopes(response: dict[str, Any]) -> list[dict[str, Any]]:
    rows = response.get("envelopes", [])
    return [row for row in rows if isinstance(row, dict)] if isinstance(rows, list) else []


def _validate_read_page(response: Any, session_id: str) -> dict[str, Any]:
    if not isinstance(response, dict) or not isinstance(response.get("envelopes"), list):
        raise NotifierError("Superset sessions read returned a malformed page")
    if not all(isinstance(row, dict) for row in response["envelopes"]):
        raise NotifierError("Superset sessions read returned malformed envelopes")
    if any(row.get("sessionId") not in (None, session_id) for row in response["envelopes"]):
        raise NotifierError("Superset sessions read returned a different session")
    cursor = response.get("nextBefore")
    if cursor is not None and not isinstance(cursor, (str, dict)):
        raise NotifierError("Superset sessions read returned a malformed cursor")
    return response


def _read_session_metadata(response: dict[str, Any]) -> tuple[Optional[str], Optional[str]]:
    status = None
    harness_session_id = None
    for envelope in _envelopes(response):
        event = envelope.get("event")
        if not isinstance(event, dict) or event.get("type") != "session":
            continue
        session = event.get("session")
        if not isinstance(session, dict):
            continue
        raw_status = session.get("status")
        raw_harness_id = session.get("harnessSessionId")
        if isinstance(raw_status, str):
            status = raw_status
        if isinstance(raw_harness_id, str) and raw_harness_id:
            harness_session_id = raw_harness_id
    return status, harness_session_id


def _provider_harness_id(
    transport: Transport, endpoint: Endpoint, sessions: list[dict[str, Any]], is_source: bool
) -> str:
    row = next((row for row in sessions if _session_id(row) == endpoint.session), None)
    value = row.get("harnessSessionId") if row else None
    if isinstance(value, str) and value:
        return value
    try:
        page = _validate_read_page(
            transport.read_session(endpoint.workspace, endpoint.session, None), endpoint.session
        )
    except SessionNotFound as exc:
        if is_source:
            raise SourceUnavailable("direct session read reports the source missing") from exc
        raise NotifierError("direct session read reports the target missing") from exc
    _, value = _read_session_metadata(page)
    if isinstance(value, str) and value:
        return value
    raise NotifierError("cannot verify provider harness session ID")


def _verify_distinct_provider_sessions(
    transport: Transport, config: Config
) -> tuple[list[dict[str, Any]], str]:
    source_rows = transport.list_sessions(config.source.workspace)
    target_rows = (source_rows if config.target.workspace == config.source.workspace
                   else transport.list_sessions(config.target.workspace))
    source_harness = _provider_harness_id(transport, config.source, source_rows, True)
    target_harness = _provider_harness_id(transport, config.target, target_rows, False)
    if source_harness == target_harness:
        raise NotifierError("source and target resolve to the same provider harness session")
    return source_rows, source_harness


@dataclass(frozen=True)
class Completion:
    harness_session_id: str
    turn_id: str
    item_id: str
    marker: str
    completed_ms: int
    epoch: str
    sequence: int

    @property
    def order(self) -> tuple[int, str, int]:
        return (self.completed_ms, self.epoch, self.sequence)


def _completed_messages(
    response: dict[str, Any], default_harness_session_id: Optional[str] = None
) -> list[Completion]:
    found: list[Completion] = []
    for envelope in _envelopes(response):
        event = envelope.get("event")
        if not isinstance(event, dict):
            continue
        # Journals may replay item updates. Only terminal completion events count.
        if event.get("type") != "item":
            continue
        item = event.get("item")
        if (not isinstance(item, dict) or item.get("kind") != "agent_message"
                or item.get("completedAtMs") is None):
            continue
        text = item.get("text")
        if not isinstance(text, str):
            continue
        completed_ms = item.get("completedAtMs")
        cursor = envelope.get("cursor")
        if (isinstance(completed_ms, bool) or not isinstance(completed_ms, int)
                or not isinstance(cursor, dict)
                or not isinstance(cursor.get("epoch"), str)
                or isinstance(cursor.get("seq"), bool)
                or not isinstance(cursor.get("seq"), int)):
            continue
        marker = _marker_line(text)
        if marker is None:
            continue
        session_info = event.get("session")
        if not isinstance(session_info, dict):
            session_info = {}
        session_id = (
            session_info.get("harnessSessionId")
            or event.get("harnessSessionId")
            or envelope.get("harnessSessionId")
            or default_harness_session_id
        )
        turn_id = event.get("turnId") or item.get("turnId")
        item_id = item.get("id") or event.get("itemId")
        if all(isinstance(x, str) and x for x in (session_id, turn_id, item_id)):
            found.append(Completion(session_id, turn_id, item_id, marker,
                                    completed_ms, cursor["epoch"], cursor["seq"]))
    return found


def _marker_line(text: str) -> Optional[str]:
    fenced = False
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith(("```", "~~~")):
            fenced = not fenced
            continue
        if not fenced and stripped in MARKERS:
            return stripped
    return None


def _turn_statuses(response: dict[str, Any]) -> dict[str, str]:
    statuses = {}
    for envelope in _envelopes(response):
        event = envelope.get("event")
        turn = event.get("turn") if isinstance(event, dict) else None
        if (isinstance(event, dict) and event.get("type") == "turn"
                and isinstance(turn, dict) and isinstance(turn.get("id"), str)
                and isinstance(turn.get("status"), str)):
            statuses[turn["id"]] = turn["status"].lower()
    return statuses


def _checkpoint_scope_key(source: Endpoint, source_harness_id: str, target: Endpoint) -> str:
    return json.dumps(
        [source.workspace, source.session, source_harness_id,
         target.workspace, target.session],
        separators=(",", ":"),
    )


def _identity(event: Completion, target: Endpoint) -> str:
    return json.dumps([target.workspace, target.session, event.harness_session_id,
                       event.turn_id, event.item_id, event.marker], separators=(",", ":"))


def _checkpoint_key(order: tuple[int, str, int]) -> dict[str, Any]:
    return {"completed_ms": order[0], "epoch": order[1], "sequence": order[2]}


def _page_bounds(response: dict[str, Any]) -> tuple[Optional[tuple[int, str, int]], Optional[tuple[int, str, int]]]:
    keys = []
    for envelope in _envelopes(response):
        cursor = envelope.get("cursor")
        if not isinstance(cursor, dict):
            continue
        epoch, sequence = cursor.get("epoch"), cursor.get("seq")
        if not isinstance(epoch, str) or isinstance(sequence, bool) or not isinstance(sequence, int):
            continue
        event = envelope.get("event")
        item = event.get("item") if isinstance(event, dict) else None
        ts = item.get("completedAtMs") if isinstance(item, dict) else None
        if isinstance(ts, bool) or not isinstance(ts, int):
            ts = envelope.get("ts")
        if isinstance(ts, bool) or not isinstance(ts, int):
            continue
        keys.append((ts, epoch, sequence))
    return (min(keys), max(keys)) if keys else (None, None)


def _next_before(response: dict[str, Any]) -> Optional[str]:
    cursor = response.get("nextBefore")
    if isinstance(cursor, dict) and cursor:
        return json.dumps(cursor, separators=(",", ":"))
    if isinstance(cursor, str) and cursor:
        return cursor
    return None


def pending_completions(
    transport: Transport, config: Config, checkpoint: tuple[int, str, int],
    listed: list[dict[str, Any]], listed_harness_id: str,
) -> tuple[list[Completion], Optional[tuple[int, str, int]], bool]:
    # A successful list call distinguishes a missing session from a live or
    # terminal row. Terminal sessions get one final history read before exit.
    source_row = next((row for row in _session_rows(listed)
                       if _session_id(row) == config.source.session), None)
    # `sessions list --limit 200` may omit older sessions. A direct read below
    # is authoritative for presence; list data is only metadata fallback.
    harness_id = source_row.get("harnessSessionId") if source_row else listed_harness_id
    if not isinstance(harness_id, str) or not harness_id:
        harness_id = None
    cursor: Optional[str] = None
    pages = 0
    completions: dict[str, Completion] = {}
    turn_statuses: dict[str, str] = {}
    newest_seen: Optional[tuple[int, str, int]] = None
    direct_status = None
    while pages < 100:
        try:
            page = _validate_read_page(
                transport.read_session(config.source.workspace, config.source.session, cursor),
                config.source.session,
            )
        except SessionNotFound as exc:
            raise SourceUnavailable("direct session read reports the source missing") from exc
        page_status, page_harness_id = _read_session_metadata(page)
        if direct_status is None and page_status is not None:
            direct_status = page_status
        if harness_id is None and page_harness_id is not None:
            harness_id = page_harness_id
        for turn_id, status in _turn_statuses(page).items():
            turn_statuses.setdefault(turn_id, status)
        lower, upper = _page_bounds(page)
        if upper is not None and (newest_seen is None or upper > newest_seen):
            newest_seen = upper
        events = _completed_messages(page, harness_id)
        for event in events:
            if event.order > checkpoint:
                completions[_identity(event, config.target)] = event
        cursor = _next_before(page)
        if cursor is None or (lower is not None and lower <= checkpoint):
            break
        pages += 1
    if pages >= 100 and cursor is not None:
        raise NotifierError("session history exceeded the 100-page scan bound")
    observation = (
        session_observation([{"sessionId": config.source.session, "status": direct_status}],
                            config.source.session)
        if direct_status is not None
        else session_observation(listed, config.source.session)
        if source_row is not None
        else "live"
    )
    candidates = sorted(completions.values(), key=lambda event: event.order)
    pending_turns = [event for event in candidates
                     if event.turn_id not in turn_statuses
                     or turn_statuses[event.turn_id] not in
                     (UNSUCCESSFUL_TURN_STATUSES | {"completed"})]
    ready = [event for event in candidates
             if turn_statuses.get(event.turn_id) == "completed"]
    safe_newest = newest_seen
    if pending_turns:
        first_pending = min(pending_turns, key=lambda event: event.order)
        pending_floor = (first_pending.completed_ms, first_pending.epoch,
                         first_pending.sequence - 1)
        if safe_newest is None or pending_floor < safe_newest:
            safe_newest = pending_floor
    return ready, safe_newest, observation == "terminal"


def build_message(task: str, event: Completion, source: Endpoint) -> str:
    status = "blocked" if event.marker == "SUPERSET_WORKER_BLOCKED" else "done"
    return (f"worker {status}: {task}\n"
            f"source workspace={source.workspace} session={source.session} "
            f"harness={event.harness_session_id} turn={event.turn_id} item={event.item_id}")


def _load_state(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {"delivered": set(), "checkpoints": {}}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        entries = data["delivered"]
        checkpoints = data.get("checkpoints", {})
        if (not isinstance(entries, list) or not all(isinstance(x, str) for x in entries)
                or not isinstance(checkpoints, dict)):
            raise ValueError
        return {"delivered": set(entries), "checkpoints": checkpoints}
    except (OSError, json.JSONDecodeError, KeyError, TypeError, ValueError) as exc:
        raise NotifierError("state file is malformed; refusing to overwrite it") from exc


def _save_state(path: Path, state: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as file:
            data = {"delivered": sorted(state["delivered"]),
                    "checkpoints": state["checkpoints"]}
            json.dump(data, file, indent=2)
            file.write("\n")
            file.flush()
            os.fsync(file.fileno())
        os.replace(tmp_name, path)
    finally:
        if os.path.exists(tmp_name):
            os.unlink(tmp_name)


def run_once(config: Config, transport: Transport, state_path: Path, dry_run: bool = False) -> bool:
    state = _load_state(state_path)
    checkpoints = state["checkpoints"]
    listed, listed_harness_id = _verify_distinct_provider_sessions(transport, config)
    checkpoint_scope = _checkpoint_scope_key(
        config.source, listed_harness_id, config.target
    )
    raw_checkpoint = checkpoints.get(checkpoint_scope)
    since_floor = (config.since_ms, "\U0010ffff", 2**63 - 1)
    if raw_checkpoint is None:
        # `since_ms` is exclusive even when multiple events share that millisecond.
        checkpoint = since_floor
    elif (isinstance(raw_checkpoint, dict)
          and isinstance(raw_checkpoint.get("completed_ms"), int)
          and isinstance(raw_checkpoint.get("epoch"), str)
          and isinstance(raw_checkpoint.get("sequence"), int)):
        checkpoint = (raw_checkpoint["completed_ms"], raw_checkpoint["epoch"], raw_checkpoint["sequence"])
    else:
        raise NotifierError("state checkpoint is malformed; refusing to overwrite it")
    checkpoint = max(checkpoint, since_floor)

    events, newest_seen, terminal = pending_completions(
        transport, config, checkpoint, listed, listed_harness_id
    )
    notified = False
    for event in events:
        identity = _identity(event, config.target)
        if identity in state["delivered"]:
            continue
        if dry_run:
            print(build_message(config.task, event, config.source))
            notified = True
            continue
        transport.send(config.target.workspace, config.target.session,
                       build_message(config.task, event, config.source))
        state["delivered"].add(identity)
        next_checkpoint = event.order
        if newest_seen is not None and newest_seen < next_checkpoint:
            next_checkpoint = newest_seen
        checkpoints[checkpoint_scope] = _checkpoint_key(next_checkpoint)
        _save_state(state_path, state)
        notified = True

    if not dry_run and newest_seen is not None and newest_seen > checkpoint:
        current = checkpoints.get(checkpoint_scope)
        current_order = checkpoint
        if isinstance(current, dict):
            current_order = (current["completed_ms"], current["epoch"], current["sequence"])
        if newest_seen > current_order:
            checkpoints[checkpoint_scope] = _checkpoint_key(newest_seen)
            _save_state(state_path, state)
    if terminal:
        raise SourceTerminal("configured source session is terminal")
    return notified


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--state", type=Path, default=DEFAULT_STATE)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--watch", action="store_true")
    parser.add_argument("--interval", type=float, default=10)
    args = parser.parse_args(argv)
    if args.interval <= 0:
        parser.error("--interval must be greater than zero")
    try:
        config = load_config(args.config)
        lock_path = args.state.with_suffix(args.state.suffix + ".lock")
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        with lock_path.open("a+") as lock:
            try:
                import fcntl
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except (ImportError, BlockingIOError) as exc:
                raise NotifierError("another notifier process is active") from exc
            transport = SupersetTransport()
            retry_delay = args.interval
            while True:
                try:
                    run_once(config, transport, args.state, args.dry_run)
                    if not args.watch:
                        return 0
                    retry_delay = args.interval
                except SourceUnavailable as exc:
                    print(f"worker notifier: source unavailable: {exc}", file=sys.stderr)
                    return 3
                except SourceTerminal as exc:
                    print(f"worker notifier: source session ended: {exc}", file=sys.stderr)
                    return 4
                except (NotifierError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
                    if not args.watch:
                        raise NotifierError(f"Superset operation failed: {exc}") from exc
                    print(f"worker notifier retry: {exc}", file=sys.stderr)
                    time.sleep(retry_delay)
                    retry_delay = min(retry_delay * 2, max(args.interval, 300))
                    continue
                time.sleep(args.interval)
    except NotifierError as exc:
        print(f"worker notifier: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
