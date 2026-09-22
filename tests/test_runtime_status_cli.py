from __future__ import annotations

from src.application.runtime_status_cli import format_runtime_status_summary


def test_format_runtime_status_summary_shows_trade_intake_sources() -> None:
    out = format_runtime_status_summary(
        {
            "ok": True,
            "data": {
                "summary": {"ok": True},
                "trade_intake": {
                    "enabled": True,
                    "mode": "apply",
                    "summary": {
                        "listener_status": "listening",
                        "processed_count": 1,
                        "failed_count": 0,
                        "unresolved_count": 0,
                    },
                    "sources": [
                        {
                            "id": "lx",
                            "account": "lx",
                            "host": "127.0.0.1",
                            "port": 11111,
                            "summary": {"listener_status": "listening"},
                        },
                        {
                            "id": "sy",
                            "account": "sy",
                            "host": "127.0.0.1",
                            "port": 11112,
                            "summary": {"listener_status": "listening"},
                        },
                    ],
                },
            },
            "warnings": [],
        }
    )

    assert "trade intake:" in out
    assert "sources=lx:listening@127.0.0.1:11111, sy:listening@127.0.0.1:11112" in out


def test_format_runtime_status_journal_summary_is_bounded_for_large_unicode_warnings() -> None:
    from src.application.runtime_status_cli import format_runtime_status_journal_summary

    out = format_runtime_status_journal_summary(
        {
            "ok": False,
            "data": {
                "summary": {"ok": False, "warning_count": 100},
                "config": {
                    "config_key": "us\nextra",
                    "config_path": "/tmp/config\ninjected-line",
                    "accounts": ["lx", "sy"],
                },
                "ledger_store": {"warnings": ["账本警告\n第二行" * 500]},
            },
            "error": {"code": "FAILED", "message": "错误" * 10000},
            "warnings": [(f"warning-{index}\n" + "警告" * 1000) for index in range(100)],
        }
    )

    assert len(out.splitlines()) <= 20
    assert len(out.encode("utf-8")) <= 16 * 1024
    assert "warnings: count=101" in out
    assert "\n第二行" not in out
    assert "\ninjected-line" not in out


def test_format_runtime_status_journal_summary_keeps_default_summary_unbounded() -> None:
    from src.application.runtime_status_cli import format_runtime_status_journal_summary

    envelope = {
        "ok": True,
        "data": {"summary": {"ok": True}},
        "warnings": ["first", "second"],
    }

    journal = format_runtime_status_journal_summary(envelope)
    default = format_runtime_status_summary(envelope)

    assert "warnings: count=2 first=first" in journal
    assert "- first" in default
    assert "- second" in default


def _seed_open_lot(db_path):
    """Write one real open short put into a fresh ledger store."""

    from src.application.ledger.manual_trades import persist_manual_open_event
    from src.application.ledger.repository import SQLiteOptionPositionsRepository

    repo = SQLiteOptionPositionsRepository(db_path)
    persist_manual_open_event(
        repo,
        broker="富途",
        account="lx",
        symbol="0700.HK",
        option_type="put",
        side="short",
        contracts=1,
        currency="HKD",
        strike=480,
        multiplier=100,
        expiration_ymd="2026-04-29",
        premium_per_share=3.93,
        opened_at_ms=100,
    )
    return db_path


def test_ledger_context_summary_rebuilds_from_store_when_cache_is_missing(tmp_path) -> None:
    """A manual ledger write drops the context cache and the prepared tick path
    never repopulates it. That missing cache must not read as "ledger
    unavailable" while the authoritative SQLite store is perfectly readable."""

    from src.application.agent_tools.runtime_status_impl import _ledger_context_summary

    db_path = _seed_open_lot(tmp_path / "option_positions.sqlite3")
    summary = _ledger_context_summary(
        {"exists": False},
        ledger_store={"sqlite_path": str(db_path)},
    )

    assert summary["available"] is True
    assert summary["status"] in {"ok", "degraded"}
    assert summary["fail_closed"] is False
    assert summary["lot_count"] >= 1
    assert summary["open_lot_count"] >= 1


def test_ledger_context_summary_rebuilds_when_cache_lacks_ledger_block(tmp_path) -> None:
    from src.application.agent_tools.runtime_status_impl import _ledger_context_summary

    db_path = _seed_open_lot(tmp_path / "option_positions.sqlite3")
    summary = _ledger_context_summary(
        {"exists": True, "json": {}},
        ledger_store={"sqlite_path": str(db_path)},
    )

    assert summary["available"] is True
    assert summary["status"] in {"ok", "degraded"}


def test_ledger_context_summary_reports_unavailable_without_resolvable_store() -> None:
    from src.application.agent_tools.runtime_status_impl import _ledger_context_summary

    for store in (None, {}, {"sqlite_path": ""}, {"sqlite_path": "/tmp/om-missing-ledger.sqlite3"}):
        summary = _ledger_context_summary({"exists": False}, ledger_store=store)
        assert summary["available"] is False
        assert summary["status"] == "unavailable"
        assert summary["fail_closed"] is False


def test_ledger_context_summary_prefers_cached_ledger_block() -> None:
    """The cache-hit branch stays untouched: an unusable store path must not
    shadow the ledger block already carried by the cache."""

    from src.application.agent_tools.runtime_status_impl import _ledger_context_summary

    summary = _ledger_context_summary(
        {
            "exists": True,
            "json": {"ledger": {"status": "blocked", "fail_closed": True, "lot_count": 7}},
        },
        ledger_store={"sqlite_path": "/tmp/om-missing-ledger.sqlite3"},
    )

    assert summary["available"] is True
    assert summary["status"] == "blocked"
    assert summary["fail_closed"] is True
    assert summary["lot_count"] == 7
