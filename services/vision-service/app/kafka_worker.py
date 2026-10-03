"""photo.submitted consumer -> photo.analyzed producer (keyed by catchId)."""
import asyncio
import logging

from pydantic import ValidationError

from .analyzer import Analyzer
from .config import Settings
from .pipeline import handle_submitted
from .schema import PhotoSubmitted

log = logging.getLogger(__name__)


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
        value=out.model_dump_json().encode(),
    )
    log.info("catch %s -> %s %s", out.catchId, out.status, out.reason or "")
    return True


async def run_worker(analyzer: Analyzer, settings: Settings, stop: asyncio.Event) -> None:
    from aiokafka import AIOKafkaConsumer, AIOKafkaProducer

    while not stop.is_set():
        consumer = AIOKafkaConsumer(
            settings.topic_in,
            bootstrap_servers=settings.kafka_bootstrap,
            group_id=settings.kafka_group_id,
            enable_auto_commit=False,
            auto_offset_reset="earliest",
        )
        producer = AIOKafkaProducer(bootstrap_servers=settings.kafka_bootstrap)
        try:
            await producer.start()
            await consumer.start()
            log.info("Kafka worker started (%s)", settings.kafka_bootstrap)
            async for rec in consumer:
                await process_record(rec.value, producer, analyzer, settings)
                await consumer.commit()  # at-least-once; central-api is idempotent
                if stop.is_set():
                    break
        except asyncio.CancelledError:
            raise
        except Exception as e:
            log.error("Kafka worker error: %s; reconnecting in 5s", e)
            await asyncio.sleep(5)
        finally:
            for c in (consumer, producer):
                try:
                    await c.stop()
                except Exception:
                    pass
