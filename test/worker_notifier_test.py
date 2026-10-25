import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / ".superset/worker_notifier.py"
SPEC = importlib.util.spec_from_file_location("worker_notifier", MODULE_PATH)
notifier = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = notifier
SPEC.loader.exec_module(notifier)


SOURCE = notifier.Endpoint("workspace-source", "session-source")
TARGET = notifier.Endpoint("workspace-target", "session-target")
CONFIG = notifier.Config(SOURCE, TARGET, "verify-notes-copy", 1792890000000)


def envelope(item_id="item-1", turn_id="turn-1", marker="SUPERSET_WORKER_DONE",
             kind="agent_message", event_type="item", text=None,
             harness="provider-session", completed_ms=1792898733213, seq=1,
             session_id=None):
    item = {"id": item_id, "kind": kind,
            "text": text if text is not None else f"finished\n{marker}\nsummary"}
    if event_type == "item" and kind == "agent_message":
        item["completedAtMs"] = completed_ms
    return {"v": 1, "sessionId": session_id or SOURCE.session, "ts": completed_ms,
            "cursor": {"epoch": "e", "seq": seq},
            "event": {"type": event_type, "turnId": turn_id,
                      "item": item}}


def session_envelope(status="running", harness_session_id="provider-session", seq=0,
                     session_id=None):
    return {"v": 1, "sessionId": session_id or SOURCE.session, "ts": CONFIG.since_ms + 5,
            "cursor": {"epoch": "e", "seq": seq},
            "event": {"type": "session", "session": {
                "status": status, "harness": "codex-acp",
                "harnessSessionId": harness_session_id,
            }}}


def turn_envelope(turn_id, status, completed_ms, seq):
    return {"v": 1, "sessionId": SOURCE.session, "ts": completed_ms,
            "cursor": {"epoch": "e", "seq": seq},
            "event": {"type": "turn", "turn": {
                "id": turn_id, "status": status,
                "completedAtMs": completed_ms if status != "running" else None,
            }}}


class FakeTransport:
    def __init__(self, pages=None, target=TARGET, auto_turn_events=True,
                 source=SOURCE, source_harness_id="provider-session"):
        self.pages = list(pages or [{"envelopes": [envelope()]}])
        self.target = target
        self.target_harness_id = "target-provider-session"
        self.auto_turn_events = auto_turn_events
        self.source = source
        self.source_harness_id = source_harness_id
        self.sent = []
        self.sent_targets = []
        self.fail_reads = 0
        self.fail_sends = 0
        self.list_response = [{"sessionId": source.session,
                               "harnessSessionId": source_harness_id,
                               "status": "running", "live": True}]
        self.read_calls = 0
        self.source_missing = False

    def list_sessions(self, workspace):
        if workspace == self.source.workspace:
            rows = list(self.list_response)
            if self.target.workspace == workspace:
                rows.append({"sessionId": self.target.session,
                             "harnessSessionId": self.target_harness_id,
                             "status": "running", "live": True})
            return rows
        if workspace == self.target.workspace:
            return [{"sessionId": self.target.session,
                     "harnessSessionId": self.target_harness_id,
                     "status": "running", "live": True}]
        raise AssertionError("wrong workspace")

    def read_session(self, workspace, session, before):
        if session == self.target.session and session != self.source.session:
            return {"ok": True, "envelopes": [session_envelope(
                harness_session_id=self.target_harness_id, session_id=self.target.session
            )]}
        self.assert_workspace(workspace)
        if session != self.source.session:
            raise AssertionError("wrong source session")
        self.read_calls += 1
        if self.source_missing:
            raise notifier.SourceUnavailable("direct session read reports the source missing")
        if self.fail_reads:
            self.fail_reads -= 1
            raise notifier.NotifierError("temporary read failure")
        if before is None:
            return self._with_turn_events(self.pages[0])
        for page in self.pages:
            if json.dumps(page.get("requestedBefore"), separators=(",", ":")) == before:
                return self._with_turn_events(page)
        raise AssertionError(f"unexpected cursor {before}")

    def _with_turn_events(self, page):
        if not self.auto_turn_events or not isinstance(page.get("envelopes"), list):
            return page
        rows = list(page["envelopes"])
        existing = {
            event.get("turn", {}).get("id")
            for envelope_row in rows
            if isinstance((event := envelope_row.get("event")), dict)
            and event.get("type") == "turn" and isinstance(event.get("turn"), dict)
        }
        seqs = [row.get("cursor", {}).get("seq", 0) for row in rows
                if isinstance(row, dict) and isinstance(row.get("cursor"), dict)]
        next_seq = max(seqs, default=0) + 1
        for row in rows:
            event = row.get("event") if isinstance(row, dict) else None
            item = event.get("item") if isinstance(event, dict) else None
            if (not isinstance(event, dict) or event.get("type") != "item"
                    or not isinstance(item, dict) or item.get("kind") != "agent_message"
                    or item.get("completedAtMs") is None):
                continue
            turn_id = event.get("turnId")
            if not isinstance(turn_id, str) or turn_id in existing:
                continue
            rows.append({"v": 1, "sessionId": self.source.session,
                         "ts": item["completedAtMs"] + 1,
                         "cursor": {"epoch": "e", "seq": next_seq},
                         "event": {"type": "turn", "turn": {
                             "id": turn_id, "status": "completed",
                             "completedAtMs": item["completedAtMs"] + 1,
                         }}})
            next_seq += 1
            existing.add(turn_id)
        return {**page, "envelopes": rows}

    def send(self, workspace, session, message):
        if self.fail_sends:
            self.fail_sends -= 1
            raise notifier.NotifierError("temporary send failure")
        self.sent_targets.append((workspace, session))
        self.sent.append(message)

    def assert_workspace(self, workspace):
        if workspace != self.source.workspace:
            raise AssertionError("wrong source workspace")


class WorkerNotifierTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.state = Path(self.temp.name) / "state.json"

    def tearDown(self):
        self.temp.cleanup()

    def test_final_marker_delivered_once_and_deduped(self):
        transport = FakeTransport()
        self.assertTrue(notifier.run_once(CONFIG, transport, self.state))
        self.assertFalse(notifier.run_once(CONFIG, transport, self.state))
        self.assertEqual(len(transport.sent), 1)
        self.assertIn("worker done: verify-notes-copy", transport.sent[0])
        self.assertIn("harness=provider-session turn=turn-1 item=item-1", transport.sent[0])

    def test_duplicate_journal_entries_are_delivered_once(self):
        duplicate = envelope()
        transport = FakeTransport([{"envelopes": [duplicate, duplicate]}])
        self.assertTrue(notifier.run_once(CONFIG, transport, self.state))
        self.assertEqual(len(transport.sent), 1)

    def test_resubmitted_task_new_turn_delivers_again(self):
        transport = FakeTransport()
        notifier.run_once(CONFIG, transport, self.state)
        transport.pages = [{"envelopes": [envelope(
            item_id="item-2", turn_id="turn-2", seq=2,
            completed_ms=1792898733223,
        )]}]
        self.assertTrue(notifier.run_once(CONFIG, transport, self.state))
        self.assertEqual(len(transport.sent), 2)

    def test_failed_read_and_send_are_retryable(self):
        transport = FakeTransport()
        transport.fail_reads = 1
        with self.assertRaises(notifier.NotifierError):
            notifier.run_once(CONFIG, transport, self.state)
        self.assertTrue(notifier.run_once(CONFIG, transport, self.state))
        transport.pages = [{"envelopes": [envelope(
            item_id="item-2", turn_id="turn-2", seq=2,
            completed_ms=1792898733223,
        )]}]
        transport.fail_sends = 1
        with self.assertRaises(notifier.NotifierError):
            notifier.run_once(CONFIG, transport, self.state)
        self.assertTrue(notifier.run_once(CONFIG, transport, self.state))
        self.assertEqual(len(transport.sent), 2)

    def test_source_equal_target_rejected(self):
        path = Path(self.temp.name) / "config.json"
        path.write_text(json.dumps({"source": {"workspace": SOURCE.workspace,
                                                "session": SOURCE.session},
                                   "target": {"workspace": SOURCE.workspace,
                                                "session": SOURCE.session},
                                   "task": "task", "since_ms": CONFIG.since_ms}))
        with self.assertRaises(notifier.NotifierError):
            notifier.load_config(path)

    def test_malformed_config_rejected(self):
        path = Path(self.temp.name) / "bad.json"
        path.write_text("{")
        with self.assertRaises(notifier.NotifierError):
            notifier.load_config(path)
        path.write_text(json.dumps({"source": {}, "target": {}, "task": ""}))
        with self.assertRaises(notifier.NotifierError):
            notifier.load_config(path)

    def test_state_uses_atomic_replacement_and_dry_run_does_not_mark(self):
        transport = FakeTransport()
        self.assertTrue(notifier.run_once(CONFIG, transport, self.state, dry_run=True))
        self.assertFalse(self.state.exists())
        self.assertEqual(transport.sent, [])
        notifier._save_state(self.state, {"delivered": {"entry"}, "checkpoints": {}})
        self.assertEqual(json.loads(self.state.read_text())["delivered"], ["entry"])
        self.assertEqual(list(self.state.parent.iterdir()), [self.state])

    def test_ignores_non_agent_messages_and_nonterminal_items(self):
        rows = [envelope(kind="reasoning"), envelope(kind="tool"),
                envelope(kind="user_message"), envelope(event_type="item.started")]
        transport = FakeTransport([{"envelopes": rows}])
        self.assertFalse(notifier.run_once(CONFIG, transport, self.state))
        self.assertEqual(transport.sent, [])

    def test_reads_past_first_hundred_events(self):
        first = {"ok": True, "envelopes": [], "nextBefore": {"epoch": "e", "seq": 100}}
        older = {"ok": True, "envelopes": [envelope()],
                 "requestedBefore": {"epoch": "e", "seq": 100}}
        transport = FakeTransport([first, older])
        self.assertTrue(notifier.run_once(CONFIG, transport, self.state))
        self.assertEqual(len(transport.sent), 1)

    def test_replayed_old_item_does_not_hide_older_page_completion(self):
        config = notifier.Config(SOURCE, TARGET, "pagination", 100)
        scope = notifier._checkpoint_scope_key(SOURCE, "provider-session", TARGET)
        notifier._save_state(self.state, {
            "delivered": set(),
            "checkpoints": {scope: {
                "completed_ms": 100, "epoch": "e", "sequence": 100,
            }},
        })
        replay = envelope(item_id="old-replay", turn_id="old-turn",
                          completed_ms=50, seq=300)
        replay["ts"] = 300
        transport = FakeTransport([
            {"envelopes": [replay, turn_envelope("unrelated", "completed", 301, 301)],
             "nextBefore": {"epoch": "e", "seq": 300}},
            {"envelopes": [
                envelope(item_id="missed-200", turn_id="turn-200",
                         completed_ms=200, seq=200),
                turn_envelope("turn-200", "completed", 201, 201),
            ], "requestedBefore": {"epoch": "e", "seq": 300}},
        ], auto_turn_events=False)
        self.assertTrue(notifier.run_once(config, transport, self.state))
        self.assertEqual(transport.read_calls, 2)
        self.assertEqual(len(transport.sent), 1)
        self.assertIn("missed-200", transport.sent[0])
        self.assertFalse(notifier.run_once(config, transport, self.state))
        self.assertEqual(len(transport.sent), 1)

    def test_legacy_checkpoint_cannot_skip_undelivered_older_completion(self):
        scope = notifier._checkpoint_scope_key(SOURCE, "provider-session", TARGET)
        notifier._save_state(self.state, {
            "delivered": set(),
            "checkpoints": {scope: {
                "completed_ms": CONFIG.since_ms + 301,
                "epoch": "z-old", "sequence": 301,
            }},
        })
        missed = envelope(item_id="missed-before-checkpoint", turn_id="missed-turn",
                          completed_ms=CONFIG.since_ms + 200, seq=200)
        missed["cursor"]["epoch"] = "a-new"
        transport = FakeTransport([{"envelopes": [missed]}])
        self.assertTrue(notifier.run_once(CONFIG, transport, self.state))
        self.assertIn("missed-before-checkpoint", transport.sent[0])
        self.assertFalse(notifier.run_once(CONFIG, transport, self.state))
        self.assertEqual(len(transport.sent), 1)

    def test_epoch_names_and_journal_timestamps_do_not_bound_pagination(self):
        config = notifier.Config(SOURCE, TARGET, "epochs", 100)
        later = envelope(item_id="later", turn_id="later-turn", completed_ms=300, seq=1)
        later["cursor"]["epoch"] = "a-new"
        later["ts"] = 1  # journal time is not the completion eligibility floor
        earlier = envelope(item_id="earlier", turn_id="earlier-turn", completed_ms=200, seq=99)
        earlier["cursor"]["epoch"] = "z-old"
        transport = FakeTransport([
            {"envelopes": [later, turn_envelope("later-turn", "completed", 301, 2)],
             "nextBefore": {"epoch": "a-new", "seq": 1}},
            {"envelopes": [earlier, turn_envelope("earlier-turn", "completed", 201, 100)],
             "requestedBefore": {"epoch": "a-new", "seq": 1}},
        ], auto_turn_events=False)
        self.assertTrue(notifier.run_once(config, transport, self.state))
        self.assertEqual(transport.read_calls, 2)
        self.assertEqual(len(transport.sent), 2)
        self.assertIn("item=earlier", transport.sent[0])
        self.assertIn("item=later", transport.sent[1])

    def test_incomplete_pagination_does_not_send_or_advance_state(self):
        next_cursor = {"epoch": "e", "seq": 10}
        transport = FakeTransport([{"envelopes": [envelope()],
                                    "nextBefore": next_cursor}])
        original_read = transport.read_session

        def fail_older_page(workspace, session, before):
            if before is not None:
                raise notifier.NotifierError("older page unavailable")
            return original_read(workspace, session, before)

        transport.read_session = fail_older_page
        with self.assertRaisesRegex(notifier.NotifierError, "older page unavailable"):
            notifier.run_once(CONFIG, transport, self.state)
        self.assertFalse(self.state.exists())
        self.assertEqual(transport.sent, [])

        transport.read_session = original_read
        transport.pages.append({"envelopes": [], "requestedBefore": next_cursor})
        self.assertTrue(notifier.run_once(CONFIG, transport, self.state))
        self.assertEqual(len(transport.sent), 1)

    def test_history_scan_bound_does_not_send_or_advance_state(self):
        transport = FakeTransport([
            {"envelopes": [envelope()], "nextBefore": {"epoch": "e", "seq": 1}},
            {"envelopes": [], "requestedBefore": {"epoch": "e", "seq": 1},
             "nextBefore": {"epoch": "e", "seq": 1}},
        ])
        with self.assertRaisesRegex(notifier.NotifierError, "100-page scan bound"):
            notifier.run_once(CONFIG, transport, self.state)
        self.assertEqual(transport.read_calls, 100)
        self.assertFalse(self.state.exists())
        self.assertEqual(transport.sent, [])

    def test_capped_list_state_is_only_metadata_not_absence_authority(self):
        response = [{"sessionId": SOURCE.session, "status": "stopped", "live": False}]
        self.assertEqual(notifier.session_observation(response, SOURCE.session), "terminal")
        self.assertEqual(notifier.session_observation([], SOURCE.session), "unknown")
        self.assertEqual(notifier.session_observation([{ "sessionId": SOURCE.session,
                                                         "status": "running", "live": True }],
                                                       SOURCE.session), "live")

    def test_terminal_source_gets_final_read_then_reports_terminal(self):
        transport = FakeTransport([{"ok": True, "envelopes": [
            session_envelope(status="stopped"), envelope(seq=1),
        ]}])
        with self.assertRaises(notifier.SourceTerminal):
            notifier.run_once(CONFIG, transport, self.state)
        self.assertEqual(len(transport.sent), 1)
        self.assertEqual(transport.read_calls, 1)

    def test_uncompleted_agent_item_and_missing_session_are_not_completion(self):
        incomplete = envelope()
        del incomplete["event"]["item"]["completedAtMs"]
        transport = FakeTransport([{"ok": True, "envelopes": [incomplete]}])
        self.assertFalse(notifier.run_once(CONFIG, transport, self.state))
        transport.list_response = []  # the 200-row list can omit old sessions
        transport.source_missing = True
        with self.assertRaises(notifier.SourceUnavailable):
            notifier.run_once(CONFIG, transport, self.state)
        self.assertEqual(transport.sent, [])

    def test_direct_read_finds_session_omitted_from_capped_list(self):
        transport = FakeTransport([{"ok": True, "envelopes": [
            session_envelope(), envelope(seq=1),
        ]}])
        transport.list_response = []
        self.assertTrue(notifier.run_once(CONFIG, transport, self.state))
        self.assertEqual(len(transport.sent), 1)

    def test_cli_direct_read_not_found_is_authoritative_absence(self):
        error = subprocess.CalledProcessError(
            1, ["superset", "sessions", "read"],
            stderr=f"Error: Chat session {SOURCE.session} not found in workspace {SOURCE.workspace}.\n",
        )
        with patch("worker_notifier.subprocess.run", side_effect=error):
            with self.assertRaises(notifier.SessionNotFound):
                notifier.SupersetTransport().read_session(
                    SOURCE.workspace, SOURCE.session, None
                )

    def test_marker_must_be_standalone_unquoted_line(self):
        quoted = envelope(text="Instructions say SUPERSET_WORKER_DONE when complete.")
        blockquoted = envelope(item_id="item-2", turn_id="turn-2",
                               text="> SUPERSET_WORKER_DONE")
        fenced = envelope(item_id="item-3", turn_id="turn-3",
                          text="```text\nSUPERSET_WORKER_DONE\n```")
        transport = FakeTransport([{"ok": True, "envelopes": [quoted, blockquoted, fenced]}])
        self.assertFalse(notifier.run_once(CONFIG, transport, self.state))
        self.assertEqual(transport.sent, [])

    def test_delayed_completion_remains_eligible_across_polls(self):
        progress = turn_envelope("unrelated", "completed", CONFIG.since_ms + 20, 20)
        transport = FakeTransport([{"envelopes": [progress]}])
        self.assertFalse(notifier.run_once(CONFIG, transport, self.state))
        scope = notifier._checkpoint_scope_key(SOURCE, "provider-session", TARGET)
        self.assertEqual(notifier._load_state(self.state)["checkpoints"][scope]["completed_ms"],
                         CONFIG.since_ms + 20)
        delayed = envelope(item_id="delayed", turn_id="delayed-turn",
                           completed_ms=CONFIG.since_ms + 15, seq=21)
        delayed["ts"] = CONFIG.since_ms + 21
        transport.pages = [{"envelopes": [progress, delayed]}]
        self.assertTrue(notifier.run_once(CONFIG, transport, self.state))
        self.assertIn("item=delayed", transport.sent[0])
        self.assertFalse(notifier.run_once(CONFIG, transport, self.state))
        self.assertEqual(len(transport.sent), 1)

    def test_long_outer_fence_keeps_nested_marker_examples_quoted(self):
        for outer, inner in (("````", "```"), ("~~~~", "~~~"),
                             ("````", "~~~~"), ("~~~~", "````")):
            with self.subTest(outer=outer, inner=inner):
                text = f"{outer}text\n{inner}\nSUPERSET_WORKER_DONE\n{inner}\n{outer}"
                self.assertIsNone(notifier._marker_line(text))
                transport = FakeTransport([{"envelopes": [envelope(text=text)]}])
                self.assertFalse(notifier.run_once(CONFIG, transport, self.state))
                self.assertEqual(transport.sent, [])

    def test_fence_closer_requires_matching_character_length_and_no_info(self):
        for closer in ("```", "~~~~", "````text"):
            with self.subTest(closer=closer):
                self.assertIsNone(notifier._marker_line(
                    f"````text\n{closer}\nSUPERSET_WORKER_DONE"
                ))
        for opening, closing in (("```", "````"), ("~~~", "~~~~")):
            with self.subTest(opening=opening):
                self.assertEqual(notifier._marker_line(
                    f"{opening}text\nSUPERSET_WORKER_BLOCKED\n{closing}\nSUPERSET_WORKER_DONE"
                ), "SUPERSET_WORKER_DONE")

    def test_omitted_endpoint_harness_metadata_can_be_on_older_page(self):
        for endpoint in (SOURCE, TARGET):
            with self.subTest(endpoint=endpoint), tempfile.TemporaryDirectory() as directory:
                transport = FakeTransport()
                original_list = transport.list_sessions
                original_read = transport.read_session
                cursor = {"epoch": "metadata", "seq": 2}
                calls = []

                def list_without_endpoint(workspace):
                    return [row for row in original_list(workspace)
                            if row["sessionId"] != endpoint.session]

                def read_with_older_metadata(workspace, session, before):
                    if (workspace, session) != (endpoint.workspace, endpoint.session):
                        return original_read(workspace, session, before)
                    calls.append(before)
                    if before is None:
                        page = original_read(workspace, session, None)
                        return {**page, "envelopes": [row for row in page["envelopes"]
                                if row["event"]["type"] != "session"], "nextBefore": cursor}
                    self.assertEqual(json.loads(before), cursor)
                    harness_id = (transport.source_harness_id if endpoint == SOURCE
                                  else transport.target_harness_id)
                    return {"envelopes": [session_envelope(
                        harness_session_id=harness_id, session_id=endpoint.session)]}

                transport.list_sessions = list_without_endpoint
                transport.read_session = read_with_older_metadata
                self.assertTrue(notifier.run_once(
                    CONFIG, transport, Path(directory) / "state.json"))
                self.assertTrue(any(before is not None for before in calls))
                self.assertEqual(len(transport.sent), 1)

    def test_older_metadata_still_rejects_same_provider_session(self):
        transport = FakeTransport()
        transport.list_response = []
        transport.pages = [
            {"envelopes": [envelope()], "nextBefore": {"epoch": "e", "seq": 1}},
            {"envelopes": [session_envelope(harness_session_id=transport.target_harness_id)],
             "requestedBefore": {"epoch": "e", "seq": 1}},
        ]
        with self.assertRaisesRegex(notifier.NotifierError, "same provider harness session"):
            notifier.run_once(CONFIG, transport, self.state)
        self.assertEqual(transport.sent, [])
        self.assertFalse(self.state.exists())

    def test_metadata_lookup_fails_closed_when_unverified_or_out_of_bounds(self):
        cursor = {"epoch": "e", "seq": 1}
        for page, error, read_count in (
            ({"envelopes": []}, "cannot verify provider", 1),
            ({"envelopes": [], "nextBefore": cursor, "requestedBefore": cursor},
             "metadata exceeded the 100-page scan bound", 100),
            ({"envelopes": [session_envelope(session_id="wrong-session")]},
             "different session", 1),
        ):
            with self.subTest(error=error):
                transport = FakeTransport([page])
                transport.list_response = []
                with self.assertRaisesRegex(notifier.NotifierError, error):
                    notifier.run_once(CONFIG, transport, self.state)
                self.assertEqual(transport.read_calls, read_count)
                self.assertEqual(transport.sent, [])
                self.assertFalse(self.state.exists())

    def test_marker_waits_for_matching_completed_turn_event(self):
        marker = envelope(seq=1)
        running_turn = {"v": 1, "sessionId": SOURCE.session,
                        "ts": marker["event"]["item"]["completedAtMs"] + 1,
                        "cursor": {"epoch": "e", "seq": 2},
                        "event": {"type": "turn", "turn": {
                            "id": "turn-1", "status": "running",
                            "completedAtMs": None,
                        }}}
        transport = FakeTransport([{"ok": True, "envelopes": [marker, running_turn]}],
                                  auto_turn_events=False)
        self.assertFalse(notifier.run_once(CONFIG, transport, self.state))
        self.assertEqual(transport.sent, [])
        completed_turn = {**running_turn, "event": {"type": "turn", "turn": {
            "id": "turn-1", "status": "completed",
            "completedAtMs": running_turn["ts"],
        }}}
        transport.pages = [{"ok": True, "envelopes": [marker, completed_turn]}]
        self.assertTrue(notifier.run_once(CONFIG, transport, self.state))
        self.assertEqual(len(transport.sent), 1)

    def test_failed_or_interrupted_turn_marker_does_not_block_later_completion(self):
        for status in ("failed", "interrupted"):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as directory:
                state = Path(directory) / "state.json"
                abandoned = envelope(item_id=f"abandoned-{status}",
                                     turn_id=f"turn-{status}",
                                     completed_ms=CONFIG.since_ms + 10, seq=10)
                abandoned_turn = turn_envelope(
                    f"turn-{status}", status, CONFIG.since_ms + 11, 11
                )
                transport = FakeTransport([{"ok": True, "envelopes": [
                    abandoned, abandoned_turn,
                ]}], auto_turn_events=False)
                self.assertFalse(notifier.run_once(CONFIG, transport, state))
                self.assertEqual(transport.sent, [])

                later = envelope(item_id="valid-after-abort", turn_id="valid-turn",
                                 completed_ms=CONFIG.since_ms + 20, seq=20)
                transport.pages = [{"ok": True, "envelopes": [
                    abandoned, abandoned_turn, later,
                    turn_envelope("valid-turn", "completed", CONFIG.since_ms + 21, 21),
                ]}]
                self.assertTrue(notifier.run_once(CONFIG, transport, state))
                self.assertEqual(len(transport.sent), 1)
                self.assertIn("valid-after-abort", transport.sent[0])

    def test_later_ready_turn_sends_without_advancing_past_pending_marker(self):
        pending = envelope(item_id="pending-item", turn_id="pending-turn",
                           completed_ms=CONFIG.since_ms + 10, seq=10)
        later = envelope(item_id="later-item", turn_id="later-turn",
                         completed_ms=CONFIG.since_ms + 20, seq=20)
        pending_turn = turn_envelope(
            "pending-turn", "running", CONFIG.since_ms + 11, 11
        )
        later_turn = turn_envelope(
            "later-turn", "completed", CONFIG.since_ms + 21, 21
        )
        transport = FakeTransport([{"ok": True, "envelopes": [
            pending, pending_turn, later, later_turn,
        ]}], auto_turn_events=False)
        self.assertTrue(notifier.run_once(CONFIG, transport, self.state))
        self.assertEqual(len(transport.sent), 1)
        self.assertIn("later-item", transport.sent[0])
        scope = notifier._checkpoint_scope_key(SOURCE, "provider-session", TARGET)
        saved = notifier._load_state(self.state)
        self.assertEqual(saved["checkpoints"][scope]["completed_ms"],
                         pending["event"]["item"]["completedAtMs"])
        self.assertLess(saved["checkpoints"][scope]["sequence"],
                        pending["cursor"]["seq"])

        transport.pages = [{"ok": True, "envelopes": [
            pending, turn_envelope("pending-turn", "completed",
                                   CONFIG.since_ms + 22, 22),
            later, later_turn,
        ]}]
        self.assertTrue(notifier.run_once(CONFIG, transport, self.state))
        self.assertEqual(len(transport.sent), 2)
        self.assertIn("pending-item", transport.sent[1])

    def test_same_provider_harness_session_is_rejected(self):
        transport = FakeTransport()
        transport.target_harness_id = "provider-session"
        with self.assertRaises(notifier.NotifierError):
            notifier.run_once(CONFIG, transport, self.state)
        self.assertEqual(transport.sent, [])

    def test_since_ms_ignores_historical_done_and_bad_fixture_does_not_mutate_state(self):
        historical = envelope(completed_ms=CONFIG.since_ms, seq=1)
        transport = FakeTransport([{"ok": True, "envelopes": [historical]}])
        self.assertFalse(notifier.run_once(CONFIG, transport, self.state))
        self.assertTrue(self.state.exists())
        self.assertEqual(transport.sent, [])
        transport.pages = [{"ok": True, "envelopes": "malformed"}]
        before = self.state.read_text()
        with self.assertRaises(notifier.NotifierError):
            notifier.run_once(CONFIG, transport, self.state)
        self.assertEqual(self.state.read_text(), before)

    def test_all_missed_completions_are_sent_chronologically(self):
        later = envelope(item_id="item-later", turn_id="turn-later",
                         completed_ms=CONFIG.since_ms + 20, seq=3)
        earlier = envelope(item_id="item-earlier", turn_id="turn-earlier",
                           completed_ms=CONFIG.since_ms + 10, seq=2)
        # Read pages newest to oldest; each page has the actual sessions read envelope shape.
        newest_page = {"ok": True, "envelopes": [later],
                       "nextBefore": {"epoch": "e", "seq": 2}}
        older_page = {"ok": True, "envelopes": [earlier],
                      "requestedBefore": {"epoch": "e", "seq": 2}}
        transport = FakeTransport([newest_page, older_page])
        self.assertTrue(notifier.run_once(CONFIG, transport, self.state))
        self.assertEqual(len(transport.sent), 2)
        self.assertIn("item-earlier", transport.sent[0])
        self.assertIn("item-later", transport.sent[1])

    def test_failed_second_send_retries_without_losing_checkpoint(self):
        first = envelope(item_id="item-1", turn_id="turn-1",
                         completed_ms=CONFIG.since_ms + 1, seq=2)
        second = envelope(item_id="item-2", turn_id="turn-2",
                          completed_ms=CONFIG.since_ms + 2, seq=3)
        page = {"ok": True, "envelopes": [first, second]}
        transport = FakeTransport([page])
        # Fail the second event by failing after one successful send.
        original_send = transport.send
        calls = {"count": 0}
        def fail_second(workspace, session, message):
            calls["count"] += 1
            if calls["count"] == 2:
                raise notifier.NotifierError("temporary second-send failure")
            original_send(workspace, session, message)
        transport.send = fail_second
        with self.assertRaises(notifier.NotifierError):
            notifier.run_once(CONFIG, transport, self.state)
        saved = notifier._load_state(self.state)
        scope_key = notifier._checkpoint_scope_key(SOURCE, "provider-session", TARGET)
        self.assertEqual(saved["checkpoints"][scope_key]["completed_ms"], first["event"]["item"]["completedAtMs"])
        transport.send = original_send
        self.assertTrue(notifier.run_once(CONFIG, transport, self.state))
        self.assertIn("item-2", transport.sent[-1])

    def test_deduplication_is_scoped_to_target(self):
        second_target = notifier.Endpoint("workspace-new", "session-new")
        transport = FakeTransport()
        notifier.run_once(CONFIG, transport, self.state)
        transport.target = second_target
        alternate = notifier.Config(SOURCE, second_target, CONFIG.task, CONFIG.since_ms)
        self.assertTrue(notifier.run_once(alternate, transport, self.state))
        self.assertEqual(transport.sent_targets[-1],
                         (second_target.workspace, second_target.session))

    def test_checkpoint_is_scoped_to_source_and_target(self):
        source_a = SOURCE
        source_b = notifier.Endpoint(SOURCE.workspace, "session-source-b")
        config_a = CONFIG
        config_b = notifier.Config(source_b, TARGET, CONFIG.task, CONFIG.since_ms)
        transport_a = FakeTransport(
            [ {"envelopes": [envelope(item_id="newer-a", turn_id="turn-a",
                                      completed_ms=CONFIG.since_ms + 100, seq=100)]} ],
            source=source_a, source_harness_id="provider-session-a",
        )
        transport_b = FakeTransport(
            [ {"envelopes": [envelope(item_id="older-b", turn_id="turn-b",
                                      completed_ms=CONFIG.since_ms + 10, seq=10,
                                      session_id=source_b.session)]} ],
            source=source_b, source_harness_id="provider-session-b",
        )
        self.assertTrue(notifier.run_once(config_a, transport_a, self.state))
        self.assertTrue(notifier.run_once(config_b, transport_b, self.state))
        self.assertIn("older-b", transport_b.sent[-1])

    def test_newer_since_ms_overrides_older_saved_checkpoint(self):
        old_checkpoint = CONFIG.since_ms + 10
        historical_marker = CONFIG.since_ms + 20
        new_config = notifier.Config(
            SOURCE, TARGET, "new-implementation", CONFIG.since_ms + 30
        )
        scope = notifier._checkpoint_scope_key(SOURCE, "provider-session", TARGET)
        notifier._save_state(self.state, {
            "delivered": set(),
            "checkpoints": {scope: {
                "completed_ms": old_checkpoint, "epoch": "e", "sequence": 10
            }},
        })
        transport = FakeTransport([{"ok": True, "envelopes": [envelope(
            item_id="old-audit-done", turn_id="old-turn",
            completed_ms=historical_marker, seq=20,
        )]}])

        self.assertFalse(notifier.run_once(new_config, transport, self.state))
        self.assertEqual(transport.sent, [])
        saved = notifier._load_state(self.state)
        self.assertEqual(saved["checkpoints"][scope]["completed_ms"], old_checkpoint)


if __name__ == "__main__":
    unittest.main()
