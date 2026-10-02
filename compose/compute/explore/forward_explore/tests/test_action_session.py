"""Delayed acceptance, cancellation and action lifetime regressions."""

import sys
import unittest
from concurrent.futures import Future
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from action_session import ActionSession


class Handle:
    accepted = True

    def __init__(self):
        self.result, self.cancel_result = Future(), Future()
        self.cancels = 0

    def get_result_async(self):
        return self.result

    def cancel_goal_async(self):
        self.cancels += 1
        return self.cancel_result


class Client:
    def __init__(self):
        self.acceptance = Future()

    def send_goal_async(self, _goal):
        return self.acceptance


class SessionTest(unittest.TestCase):
    def setUp(self):
        self.client, self.handle = Client(), Handle()
        self.session = ActionSession(self.client, object(), 0, execution_timeout=10)

    def accept(self):
        self.client.acceptance.set_result(self.handle)
        self.session.poll(1)

    def test_pause_before_acceptance_still_cancels_late_goal(self):
        self.session.cancel(0.5, "paused")
        self.accept()
        self.assertEqual(self.handle.cancels, 1)
        self.assertFalse(self.session.active)
        self.assertFalse(self.session.done)
        self.session.poll(2)
        self.assertEqual(self.handle.cancels, 1)

    def test_acceptance_has_a_deadline(self):
        self.session.poll(3.1)
        self.assertEqual(self.session.reason, "goal acceptance timeout")
        self.client.acceptance.set_result(self.handle)
        self.session.poll(4)
        self.assertEqual(self.handle.cancels, 1)
        self.session.poll(7)
        self.assertTrue(self.session.unsafe)

    def test_cancel_ack_is_not_terminal_result(self):
        self.accept()
        self.session.cancel(2, "paused")
        self.handle.cancel_result.set_result(SimpleNamespace(goals_canceling=[object()]))
        self.session.poll(2.1)
        self.assertFalse(self.session.done)
        self.handle.result.set_result(SimpleNamespace(status=5))
        self.session.poll(2.2)
        self.assertTrue(self.session.done)
        self.assertEqual(self.session.status, 5)

    def test_acceptance_after_deadline_is_cancelled_even_before_first_poll(self):
        self.client.acceptance.set_result(self.handle)
        self.session.poll(4)
        self.assertEqual(self.session.reason, "goal acceptance timeout")
        self.assertEqual(self.handle.cancels, 1)
        self.assertFalse(self.session.active)

    def test_rejected_cancellation_fails_closed(self):
        self.accept()
        self.session.cancel(2, "paused")
        self.handle.cancel_result.set_result(SimpleNamespace(goals_canceling=[]))
        self.session.poll(2.1)
        self.assertTrue(self.session.unsafe)

    def test_execution_timeout_stops_authorizing_motion(self):
        self.accept()
        self.assertTrue(self.session.active)
        self.session.poll(11)
        self.assertFalse(self.session.active)
        self.assertEqual(self.handle.cancels, 1)

    def test_transport_failure_revokes_authorization(self):
        self.client.acceptance.set_exception(RuntimeError("server disappeared"))
        self.session.poll(1)
        self.assertTrue(self.session.unsafe)
        self.assertIn("transport error", self.session.reason)

    def test_rejected_goal_is_terminal(self):
        self.handle.accepted = False
        self.accept()
        self.assertTrue(self.session.done)
        self.assertFalse(self.session.active)


if __name__ == "__main__":
    unittest.main()
