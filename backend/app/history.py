"""Daily per-broker portfolio values for the widget's 30-day sparkline.

Every refresh upserts today's value, so the row left at the end of a (UTC) day is
that day's close. NSE (10:00 UTC) and NYSE (20:00/21:00 UTC) both close inside
the same UTC day, so one date key works for both brokers.
"""

import sqlite3
from datetime import datetime, timedelta
from pathlib import Path

from app.schemas import HistoryPoint


class HistoryStore:
    def __init__(self, path: Path) -> None:
        if str(path) != ":memory:":
            path.parent.mkdir(parents=True, exist_ok=True)
        self._db = sqlite3.connect(path, check_same_thread=False)
        self._db.execute(
            """
            CREATE TABLE IF NOT EXISTS daily_values (
                day TEXT NOT NULL,
                broker TEXT NOT NULL,
                value REAL NOT NULL,
                recorded_at TEXT NOT NULL,
                PRIMARY KEY (day, broker)
            )
            """
        )
        self._db.commit()

    def close(self) -> None:
        self._db.close()

    def record(self, at: datetime, values: dict[str, float]) -> None:
        day = at.date().isoformat()
        self._db.executemany(
            """
            INSERT INTO daily_values (day, broker, value, recorded_at) VALUES (?, ?, ?, ?)
            ON CONFLICT (day, broker) DO UPDATE SET value = excluded.value, recorded_at = excluded.recorded_at
            """,
            [(day, broker, value, at.isoformat()) for broker, value in values.items()],
        )
        self._db.commit()

    def daily(self, today: datetime, days: int, brokers: list[str]) -> list[HistoryPoint]:
        """Closes for the `days` days before `today`, oldest first.

        A broker missing on some day (backend was down, broker failed) carries its previous
        value forward; days before a broker's first record are skipped so the sparkline
        never shows a fake drop to zero.
        """
        start = (today - timedelta(days=days)).date().isoformat()
        rows = self._db.execute(
            "SELECT day, broker, value, recorded_at FROM daily_values WHERE day >= ? AND day < ? ORDER BY day",
            (start, today.date().isoformat()),
        ).fetchall()

        by_day: dict[str, tuple[dict[str, float], str]] = {}
        for day, broker, value, recorded_at in rows:
            values, latest = by_day.get(day, ({}, recorded_at))
            values[broker] = value
            by_day[day] = (values, max(latest, recorded_at))

        points: list[HistoryPoint] = []
        carried: dict[str, float] = {}
        for day in sorted(by_day):
            values, recorded_at = by_day[day]
            carried.update(values)
            if all(b in carried for b in brokers):
                points.append(
                    HistoryPoint(
                        timestamp=datetime.fromisoformat(recorded_at),
                        values={b: carried[b] for b in brokers},
                    )
                )
        return points
