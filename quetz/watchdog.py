"""Diagnostics for server hangs.

A daemon thread checks that the asyncio event loop keeps running. When the loop
does not answer a heartbeat for ``stall_seconds`` it logs a WARNING with:

- the stack of every thread (shows what blocks the loop, or what the worker
  threads are waiting on),
- the AnyIO threadpool usage (borrowed vs. total tokens), to tell "event loop
  blocked" apart from "threadpool starved",
- the number of open DB sessions and the age of the oldest one.

It only logs while a stall lasts (once per ``repeat_seconds``) and is otherwise
silent. A hang can also be inspected manually by sending SIGUSR1 to the process
(``kill -USR1 <pid>``), which dumps all thread stacks to stderr.
"""

import asyncio
import faulthandler
import logging
import os
import signal
import sys
import threading
import time
import traceback
from typing import Dict, Optional

logger = logging.getLogger("quetz")

# id(session) -> monotonic time at which it was opened
_open_sessions: Dict[int, float] = {}
_open_sessions_lock = threading.Lock()


def session_opened(session) -> None:
    with _open_sessions_lock:
        _open_sessions[id(session)] = time.monotonic()


def session_closed(session) -> Optional[float]:
    """Forget the session; returns for how many seconds it was open."""
    with _open_sessions_lock:
        started = _open_sessions.pop(id(session), None)
    return None if started is None else time.monotonic() - started


def _threadpool_usage(limiter) -> str:
    if limiter is None:
        return "threadpool usage unavailable"
    try:
        return f"{limiter.borrowed_tokens}/{limiter.total_tokens} threads in use"
    except Exception as e:
        return f"threadpool usage unavailable ({e!r})"


def _dump_threads() -> str:
    names = {t.ident: t.name for t in threading.enumerate()}
    chunks = []
    for ident, frame in sys._current_frames().items():
        chunks.append(f"--- thread {names.get(ident, '?')} ({ident}) ---")
        chunks.append("".join(traceback.format_stack(frame)))
    return "\n".join(chunks)


def _sessions_summary() -> str:
    now = time.monotonic()
    with _open_sessions_lock:
        ages = [now - t for t in _open_sessions.values()]
    if not ages:
        return "0 open DB sessions"
    return f"{len(ages)} open DB sessions, oldest {max(ages):.1f}s"


class EventLoopWatchdog:
    def __init__(
        self,
        loop: asyncio.AbstractEventLoop,
        stall_seconds: float = 5.0,
        check_interval: float = 1.0,
        repeat_seconds: float = 30.0,
    ):
        self.loop = loop
        self.stall_seconds = stall_seconds
        self.check_interval = check_interval
        self.repeat_seconds = repeat_seconds
        self._last_beat = time.monotonic()
        self._limiter = None
        self._stop = threading.Event()
        self._thread = threading.Thread(
            target=self._run, name="quetz-loop-watchdog", daemon=True
        )

    def start(self) -> None:
        """Start watching. Must be called from inside the running event loop."""
        try:
            # only obtainable from the loop thread; read from the watchdog thread
            import anyio.to_thread

            self._limiter = anyio.to_thread.current_default_thread_limiter()
        except Exception:
            logger.debug("could not get the AnyIO thread limiter", exc_info=True)
        try:
            faulthandler.register(signal.SIGUSR1, all_threads=True)
        except (AttributeError, ValueError, RuntimeError):
            pass  # not supported on this platform / not in main thread
        self._thread.start()
        logger.info(
            "event loop watchdog started (stall threshold %ss)", self.stall_seconds
        )

    def stop(self) -> None:
        self._stop.set()

    def _beat(self) -> None:
        self._last_beat = time.monotonic()

    def _run(self) -> None:
        last_report = 0.0
        while not self._stop.wait(self.check_interval):
            if self.loop.is_closed():
                return
            try:
                self.loop.call_soon_threadsafe(self._beat)
            except RuntimeError:
                return
            stalled = time.monotonic() - self._last_beat
            if stalled < self.stall_seconds:
                last_report = 0.0
                continue
            now = time.monotonic()
            if now - last_report < self.repeat_seconds:
                continue
            last_report = now
            logger.warning(
                "event loop has not responded for %.1fs (pid %s); %s; %s\n%s",
                stalled,
                os.getpid(),
                _threadpool_usage(self._limiter),
                _sessions_summary(),
                _dump_threads(),
            )
