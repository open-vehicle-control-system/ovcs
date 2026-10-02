"""One action at a time, retaining cancellation across delayed goal acceptance."""


class ActionSession:
    def __init__(self, client, goal, now, acceptance_timeout=3.0, execution_timeout=60.0):
        self.sent_at = now
        self.acceptance_timeout = acceptance_timeout
        self.execution_timeout = execution_timeout
        self.acceptance = client.send_goal_async(goal)
        self.handle = None
        self.result = None
        self.cancellation = None
        self.cancelled_at = None
        self.reason = None
        self.status = None
        self.unsafe = False

    @property
    def active(self):
        return self.handle is not None and self.status is None and self.cancelled_at is None

    @property
    def done(self):
        return self.status is not None

    def cancel(self, now, reason):
        if self.cancelled_at is None:
            self.cancelled_at, self.reason = now, reason
        if self.handle is not None and self.cancellation is None and not self.done:
            try:
                self.cancellation = self.handle.cancel_goal_async()
            except Exception as error:  # noqa: BLE001 - Cancellation can fail after server loss.
                self.reason = f"cancellation transport error: {error!r}"
                self.unsafe = True

    def poll(self, now):
        try:
            self._poll(now)
        except Exception as error:  # noqa: BLE001 - Transport errors revoke motion too.
            self.reason = f"action transport error: {error!r}"
            self.unsafe = True

    def _poll(self, now):
        if self.done:
            return
        if self.handle is None:
            if now - self.sent_at > self.acceptance_timeout:
                self.cancel(now, "goal acceptance timeout")
            if not self.acceptance.done():
                self.check_cancel_timeout(now)
                return
            self.handle = self.acceptance.result()
            if not self.handle.accepted:
                self.status, self.reason = 6, "goal rejected"
                return
            self.result = self.handle.get_result_async()
            if self.cancelled_at is not None:
                self.cancel(now, self.reason)
        if self.result.done():
            self.status = self.result.result().status
            return
        if now - self.sent_at > self.execution_timeout:
            self.cancel(now, "goal execution timeout")
        if (
            self.cancellation is not None
            and self.cancellation.done()
            and not self.cancellation.result().goals_canceling
        ):
            self.unsafe = True
        self.check_cancel_timeout(now)

    def check_cancel_timeout(self, now):
        if self.cancelled_at is not None and now - self.cancelled_at > 3.0:
            # The caller must revoke its motion lease and end the mission.
            self.unsafe = True
