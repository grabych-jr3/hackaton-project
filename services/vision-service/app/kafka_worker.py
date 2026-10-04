"""photo.submitted consumer -> photo.analyzed producer (keyed by catchId).

The consumer runs under a supervisor: any exception, a stopped consumer (e.g. after
LeaveGroup) or a missing partition assignment for > WATCHDOG_S recreates the consumer
after a short backoff, forever, until the service shuts down.
"""
import asyncio
import logging
import time
from dataclasses import dataclass, field
from typing import Any, Callable

from pydantic import ValidationError

from .analyzer import Analyzer
from .config import Settings
from .pipeline import handle_submitted
from .schema import PhotoSubmitted

log = logging.getLogger(__name__)

BACKOFFS = (1, 2, 5, 10, 30)  # seconds; the last value repeats forever
WATCHDOG_S = 60.0             # no assignment for this long while running -> recreate consumer
POLL_TIMEOUT_MS = 1000


class ConsumerUnhealthy(RuntimeError):
    pass


@dataclass
class WorkerState:
    running: bool = False
    connected: bool = False
    assigned: list[str] = field(default_factory=list)
    last_message_at: float | None = None
    restarts: int = 0
    last_error: str | None = None

    def snapshot(self) -> dict:
        return {
            "running": self.running,
            "connected": self.connected,
            "assignedPartitions": list(self.assigned),
            "lastMessageAt": (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(self.last_message_at))
                              if self.last_message_at else None),
            "restarts": self.restarts,
            "lastError": self.last_error,
        }


async def process_record(value: bytes, producer, analyzer: Analyzer, settings: Settings,
                         retry_delay: float = 0.5) -> bool:
    """Handle one record. Returns False for malformed (skipped) messages."""
    try:
        msg = PhotoSubmitted.model_validate_json(value)
    except ValidationError as e:
        log.error("skipping malformed photo.submitted: %s", e)
        return False
    out = await handle_submitted(msg, analyzer, settings, retry_delay)
    await producer.send_and_wait(
        settings.topic_out,
        key=msg.catchId.encode(),
        value=out.model_dump_json(exclude_none=False).encode(),
    )
    log.info("catch %s -> %s model=%s %s", out.catchId, out.status, out.model, out.reason or "")
    return True


def default_consumer(settings: Settings):
    from aiokafka import AIOKafkaConsumer

    return AIOKafkaConsumer(
        settings.topic_in,
        bootstrap_servers=settings.kafka_bootstrap,
        group_id=settings.kafka_group_id,
        enable_auto_commit=False,
        auto_offset_reset="earliest",
        max_poll_interval_ms=300000,
        session_timeout_ms=30000,
        heartbeat_interval_ms=3000,
        max_poll_records=1,
    )


def default_producer(settings: Settings):
    from aiokafka import AIOKafkaProducer

    return AIOKafkaProducer(bootstrap_servers=settings.kafka_bootstrap)


async def _session(consumer, producer, analyzer: Analyzer, settings: Settings, stop: asyncio.Event,
                   state: WorkerState, watchdog_s: float, clock: Callable[[], float]) -> None:
    """One consumer lifetime. Returns only on stop; raises when the consumer must be recreated."""
    await producer.start()
    await consumer.start()
    state.connected = True
    log.info("Kafka worker started (%s, group=%s)", settings.kafka_bootstrap, settings.kafka_group_id)
    unassigned_since = clock()
    while not stop.is_set():
        batches = await consumer.getmany(timeout_ms=POLL_TIMEOUT_MS)
        for tp, records in batches.items():
            for rec in records:
                state.last_message_at = time.time()
                await process_record(rec.value, producer, analyzer, settings)
                await consumer.commit({tp: rec.offset + 1})  # commit only after the result is produced
        assignment = consumer.assignment() or set()
        state.assigned = sorted(f"{tp.topic}-{tp.partition}" for tp in assignment)
        if assignment:
            unassigned_since = clock()
        elif clock() - unassigned_since > watchdog_s:
            raise ConsumerUnhealthy(f"no partition assignment for > {watchdog_s:.0f}s")


async def run_worker(analyzer: Analyzer, settings: Settings, stop: asyncio.Event,
                     state: WorkerState | None = None,
                     consumer_factory: Callable[[Settings], Any] = default_consumer,
                     producer_factory: Callable[[Settings], Any] = default_producer,
                     backoffs: tuple = BACKOFFS, watchdog_s: float = WATCHDOG_S,
                     clock: Callable[[], float] = time.monotonic) -> None:
    """Supervisor: (re)create the consumer forever until `stop` is set."""
    state = state or WorkerState()
    state.running = True
    failures = 0
    try:
        while not stop.is_set():
            consumer = producer = None
            try:
                consumer = consumer_factory(settings)
                producer = producer_factory(settings)
                await _session(consumer, producer, analyzer, settings, stop, state, watchdog_s, clock)
                failures = 0
            except asyncio.CancelledError:
                raise
            except Exception as e:
                state.last_error = f"{type(e).__name__}: {e}"
                log.error("Kafka worker error: %s -> recreating consumer", state.last_error)
            finally:
                state.connected = False
                state.assigned = []
                for c in (consumer, producer):
                    if c is None:
                        continue
                    try:
                        await c.stop()
                    except Exception:
                        pass
            if stop.is_set():
                break
            delay = backoffs[min(failures, len(backoffs) - 1)] if backoffs else 0
            failures += 1
            state.restarts += 1
            log.warning("Kafka consumer restart #%d in %ss", state.restarts, delay)
            try:
                await asyncio.wait_for(stop.wait(), timeout=delay)
            except asyncio.TimeoutError:
                pass
    finally:
        state.running = False
