#!/usr/bin/env python3
"""
Run with:
  uvx --with "psycopg[binary]" python tests/bpostgres_sync.py
"""

from __future__ import annotations

import os
import time
from dataclasses import dataclass

import psycopg


@dataclass(slots=True)
class BenchResult:
    label: str
    rows: int
    checksum: int
    elapsed_ms: float


def env(name: str, default: str) -> str:
    value = os.environ.get(name, "")
    return value if value else default


def env_int(name: str, default: int) -> int:
    value = os.environ.get(name, "")
    return int(value) if value else default


def connection_kwargs() -> dict[str, str]:
    return {
        "host": env("SQUEAL_PG_HOST", "127.0.0.1"),
        "port": env("SQUEAL_PG_PORT", "55432"),
        "user": env("SQUEAL_PG_USER", os.environ.get("USER", "")),
        "password": os.environ.get("SQUEAL_PG_PASSWORD", ""),
        "dbname": env("SQUEAL_PG_DATABASE", "squeal_bench"),
    }


def setup_bench_data(conn: psycopg.Connection, row_count: int) -> None:
    with conn.cursor() as cur:
        cur.execute("set client_min_messages = warning")
        cur.execute("drop table if exists squeal_bench")
        cur.execute(
            """
            create table squeal_bench(
              id int8 primary key,
              name text not null,
              active bool not null,
              age int4 not null,
              shard int2 not null,
              score float8 not null,
              ratio float4 not null,
              tag text not null,
              balance int8 not null
            )
            """
        )
        cur.execute(
            """
            insert into squeal_bench(
              id, name, active, age, shard, score, ratio, tag, balance
            )
            select
              i::int8,
              'name-' || i::text,
              (i %% 2 = 0),
              (i %% 1000)::int4,
              (i %% 17)::int2,
              i::float8 / 10.0,
              (i %% 100)::float4 / 3.0,
              'tag-' || (i %% 100)::text,
              i::int8 * 97
            from generate_series(1, %s) as i
            """,
            (row_count,),
        )
    conn.commit()


def bench_psycopg(conn: psycopg.Connection, iterations: int) -> BenchResult:
    start = time.monotonic_ns()
    rows_total = 0
    checksum = 0

    for _ in range(iterations):
        with conn.cursor() as cur:
            cur.execute(
                """
                select id, name, active, age, shard, score, ratio, tag, balance
                from squeal_bench
                order by id
                """
            )
            rows = cur.fetchall()

        rows_total += len(rows)
        for row_id, name, active, age, shard, score, ratio, tag, balance in rows:
            checksum += row_id
            checksum += len(name)
            if active:
                checksum += 1
            checksum += age
            checksum += shard
            checksum += int(score * 1000.0)
            checksum += int(ratio * 1000.0)
            checksum += len(tag)
            checksum += balance

    elapsed_ms = (time.monotonic_ns() - start) / 1_000_000.0
    return BenchResult(
        label="python psycopg sync tuple",
        rows=rows_total,
        checksum=checksum,
        elapsed_ms=elapsed_ms,
    )


def print_result(result: BenchResult) -> None:
    rows_per_sec = 0.0
    if result.elapsed_ms:
        rows_per_sec = result.rows / (result.elapsed_ms / 1000.0)
    print(result.label)
    print(f"  rows:      {result.rows}")
    print(f"  checksum:  {result.checksum}")
    print(f"  elapsed:   {result.elapsed_ms:.3f} ms")
    print(f"  rows/sec:  {rows_per_sec:.0f}")


def main() -> int:
    row_count = env_int("SQUEAL_BENCH_ROWS", 40_000)
    iterations = env_int("SQUEAL_BENCH_ITERS", 200)

    with psycopg.connect(**connection_kwargs()) as conn:
        setup_bench_data(conn, row_count)
        result = bench_psycopg(conn, iterations)

    print("PostgreSQL fetch benchmark")
    print(f"  rows/iteration: {row_count}")
    print(f"  iterations:     {iterations}")
    print()
    print_result(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
