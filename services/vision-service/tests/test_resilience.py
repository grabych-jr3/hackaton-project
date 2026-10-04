"""Model rotation, cooldown, time budget, consumer supervisor and /health (genai & kafka mocked)."""
import asyncio
import json
from collections import namedtuple

from app.config import Settings, parse_models
from app.kafka_worker import WorkerState, run_worker
from app.pipeline import REASON_FAILED, analyze_bytes
from app.rotation import ModelCooldown, classify_error
from tests.test_vision import VALID, _jpeg, settings, sharp

run = asyncio.run
IMG = _jpeg(sharp())


class APIError(Exception):
    """Shape of google.genai.errors.APIError (code + status)."""

    def __init__(self, code, status, msg=""):
        super().__init__(f"{code} {status}. {msg}")
        self.code = code
        self.status = status


def e503():
    return APIError(503, "UNAVAILABLE", "The model is currently experiencing high demand")


class RotAnalyzer:
    name = "gemini"

    def __init__(self, models, script, delay=0.0):
        self.models = models
        self.script = {m: list(v) for m, v in script.items()}
        self.calls: list[str] = []
        self.delay = delay

    async def analyze(self, jpeg, model=None):
        self.calls.append(model)
        if self.delay:
            await asyncio.sleep(self.delay)
        r = self.script[model].pop(0) if self.script.get(model) else e503()
        if isinstance(r, Exception):
            raise r
        return r


OK = json.dumps(VALID)
M = ["m1", "m2", "m3"]


def test_parse_models_defaults_and_primary_first():
    assert parse_models("", "")[0] == "gemini-3.7-flash" and len(parse_models(None, None)) == 5
    assert parse_models("x", "a, x ,b") == ["x", "a", "b"]


def test_classify():
    assert classify_error(e503()) == "overloaded"
    assert classify_error(APIError(429, "RESOURCE_EXHAUSTED")) == "overloaded"
    assert classify_error(APIError(404, "NOT_FOUND")) == "not_found"
    assert classify_error(APIError(500, "INTERNAL")) == "error"


def test_503_rotates_to_next_model_and_reports_model():
    a = RotAnalyzer(M, {"m1": [e503()], "m2": [OK]})
    cd = ModelCooldown()
    out = run(analyze_bytes("c", IMG, a, settings(), retry_delay=0, cooldown=cd))
    assert out.status == "OK" and out.model == "m2" and a.calls == ["m1", "m2"]
    assert cd.is_cooling("m1") and not cd.is_cooling("m2")
    assert json.loads(out.model_dump_json())["model"] == "m2"


def test_404_skips_model_without_cooldown_and_not_retried():
    a = RotAnalyzer(M, {"m1": [APIError(404, "NOT_FOUND")], "m2": [e503()] * 2, "m3": [e503()] * 2})
    cd = ModelCooldown()
    out = run(analyze_bytes("c", IMG, a, settings(), retry_delay=0, cooldown=cd))
    assert out.status == "FAILED"
    assert a.calls.count("m1") == 1 and a.calls.count("m2") == 2  # retired model skipped in pass 2
    assert not cd.is_cooling("m1")


def test_cooldown_model_tried_last_on_next_photo():
    t = [0.0]
    cd = ModelCooldown(120, clock=lambda: t[0])
    cd.mark("m1")
    a = RotAnalyzer(M, {"m2": [OK]})
    out = run(analyze_bytes("c", IMG, a, settings(), retry_delay=0, cooldown=cd))
    assert out.model == "m2" and a.calls == ["m2"]
    assert cd.order(M) == ["m2", "m3", "m1"]
    t[0] = 121
    assert cd.order(M) == M and not cd.is_cooling("m1")


def test_all_models_fail_two_passes_failed_reason():
    a = RotAnalyzer(M, {})
    out = run(analyze_bytes("c", IMG, a, settings(), retry_delay=0, cooldown=ModelCooldown()))
    assert out.status == "FAILED" and out.reason == REASON_FAILED and out.model is None
    assert len(a.calls) == 6  # at most 2 passes


def test_invalid_json_retry_same_model_then_next():
    a = RotAnalyzer(M, {"m1": ["{bad", "{bad"], "m2": [OK]})
    out = run(analyze_bytes("c", IMG, a, settings(), retry_delay=0, cooldown=ModelCooldown()))
    assert out.model == "m2" and a.calls == ["m1", "m1", "m2"]


def test_invalid_json_then_ok_same_model():
    a = RotAnalyzer(M, {"m1": ["{bad", OK]})
    out = run(analyze_bytes("c", IMG, a, settings(), retry_delay=0, cooldown=ModelCooldown()))
    assert out.model == "m1" and a.calls == ["m1", "m1"]


def test_time_budget_and_per_call_timeout():
    s = settings()
    s.ai_time_budget = 0.3
    s.ai_call_timeout = 0.1
    a = RotAnalyzer(M, {"m1": [OK] * 9, "m2": [OK] * 9, "m3": [OK] * 9}, delay=5)
    loop_t = []

    async def go():
        t0 = asyncio.get_running_loop().time()
        out = await analyze_bytes("c", IMG, a, s, retry_delay=0, cooldown=ModelCooldown())
        loop_t.append(asyncio.get_running_loop().time() - t0)
        return out

    out = run(go())
    assert out.status == "FAILED" and out.reason == REASON_FAILED
    assert loop_t[0] < 1.0 and len(a.calls) >= 3  # every call timed out, budget respected


# ---------- supervisor ----------

TP = namedtuple("TP", "topic partition")
Rec = namedtuple("Rec", "value offset")


class FakeConsumer:
    def __init__(self, behaviour, stop):
        self.behaviour = behaviour  # "boom" | "ok" | "unassigned"
        self.stop_evt = stop
        self.started = self.stopped = False
        self.commits = []
        self.served = False

    async def start(self):
        self.started = True

    async def stop(self):
        self.stopped = True

    def assignment(self):
        return set() if self.behaviour == "unassigned" else {TP("photo.submitted", 0)}

    async def getmany(self, timeout_ms=0):
        await asyncio.sleep(0)
        if self.behaviour == "boom":
            raise RuntimeError("LeaveGroup / consumer stopped")
        if self.behaviour == "ok" and not self.served:
            self.served = True
            return {TP("photo.submitted", 0): [Rec(b"{}", 7)]}
        if self.behaviour == "ok":
            self.stop_evt.set()
        return {}

    async def commit(self, offsets=None):
        self.commits.append(offsets)


class FakeProducer:
    def __init__(self):
        self.sent = []

    async def start(self):
        pass

    async def stop(self):
        pass

    async def send_and_wait(self, topic, key=None, value=None):
        self.sent.append((topic, key, value))


def _supervise(behaviours, **kw):
    stop = asyncio.Event()
    created = []
    state = WorkerState()

    def cf(_s):
        c = FakeConsumer(behaviours[min(len(created), len(behaviours) - 1)], stop)
        created.append(c)
        return c

    async def go():
        await asyncio.wait_for(
            run_worker(object(), settings(), stop, state, consumer_factory=cf,
                       producer_factory=lambda _s: FakeProducer(), backoffs=(0,), **kw), 5)

    run(go())
    return created, state


def test_supervisor_recreates_consumer_after_exception():
    created, state = _supervise(["boom", "boom", "ok"])
    assert len(created) == 3 and all(c.stopped for c in created)
    assert state.restarts == 2 and "LeaveGroup" in state.last_error and not state.running
    assert created[2].commits == [{TP("photo.submitted", 0): 8}]  # commit after processing
    assert state.last_message_at is not None


def test_watchdog_recreates_unassigned_consumer():
    t = [0.0]

    def clock():
        t[0] += 10
        return t[0]

    created, state = _supervise(["unassigned", "ok"], watchdog_s=60, clock=clock)
    assert len(created) == 2 and "assignment" in state.last_error


# ---------- health ----------

def test_health_payload(monkeypatch):
    monkeypatch.setenv("KAFKA_ENABLED", "false")
    monkeypatch.setenv("GEMINI_API_KEY", "")
    from fastapi.testclient import TestClient
    from app.main import app

    with TestClient(app) as c:
        app.state.worker.connected = True
        app.state.worker.assigned = ["photo.submitted-0"]
        d = c.get("/health").json()
    assert d["kafkaConnected"] is True and d["assignedPartitions"] == ["photo.submitted-0"]
    assert "lastMessageAt" in d and d["models"] == {"mock": {"cooldown": False, "remainingS": 0}}
    assert Settings().gemini_models  # sanity
