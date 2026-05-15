import std/[monotimes, os, strutils, times]

import squeal

type
  BenchRow = object
    id: int64
    name: string
    active: bool
    age: int32
    shard: int16
    score: float64
    ratio: float32
    tag: string
    balance: int64

  BenchResult = object
    label: string
    rows: int
    checksum: int64
    elapsedMs: float

proc env(name, defaultValue: string): string =
  result = getEnv(name)
  if result.len == 0:
    result = defaultValue

proc envInt(name: string, defaultValue: int): int =
  let value = getEnv(name)
  if value.len == 0:
    defaultValue
  else:
    parseInt(value)

proc elapsedMs(start: MonoTime): float =
  float((getMonoTime() - start).inMicroseconds) / 1000.0

proc openBenchDb(): DbConn =
  open(
    env("SQUEAL_PG_HOST", "127.0.0.1") & ":" & env("SQUEAL_PG_PORT", "55432"),
    env("SQUEAL_PG_USER", getEnv("USER")),
    env("SQUEAL_PG_PASSWORD", ""),
    env("SQUEAL_PG_DATABASE", "squeal_test"),
  )

proc execSql(db: DbConn, query: string) =
  db.exec(SqlQuery(query))

proc setupBenchData(db: DbConn, rowCount: int) =
  db.execSql("set client_min_messages = warning")
  db.execSql("drop table if exists squeal_bench")
  db.execSql(
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
  db.execSql(
    "insert into squeal_bench(id, name, active, age, shard, score, ratio, tag, balance) " &
      "select i::int8, 'name-' || i::text, (i % 2 = 0), " &
      "(i % 1000)::int4, (i % 17)::int2, i::float8 / 10.0, (i % 100)::float4 / 3.0, " &
      "'tag-' || (i % 100)::text, i::int8 * 97 " &
      "from generate_series(1, " & $rowCount & ") as i"
  )

proc benchDbConnector(db: DbConn, iterations: int): BenchResult =
  let start = getMonoTime()
  for _ in 0 ..< iterations:
    let rows =
      db.getAllRows(
        sql"""
          select id, name, active, age, shard, score, ratio, tag, balance
          from squeal_bench
          order by id
        """
      )
    result.rows += rows.len
    for row in rows:
      result.checksum += parseInt(row[0])
      result.checksum += row[1].len
      if row[2] == "t":
        inc result.checksum
      result.checksum += parseInt(row[3])
      result.checksum += parseInt(row[4])
      result.checksum += int64(parseFloat(row[5]) * 1000.0)
      result.checksum += int64(parseFloat(row[6]) * 1000.0)
      result.checksum += row[7].len
      result.checksum += parseInt(row[8])

  result.label = "db_connector text Row"
  result.elapsedMs = elapsedMs(start)

proc benchSqueal(db: DbConn, iterations: int): BenchResult =
  let start = getMonoTime()
  for _ in 0 ..< iterations:
    let rows = getAll[BenchRow](
      db,
      sql"""
        select id, name, active, age, shard, score, ratio, tag, balance
        from squeal_bench
        order by id
      """,
    )
    result.rows += rows.len
    for row in rows:
      result.checksum += row.id
      result.checksum += row.name.len
      if row.active:
        inc result.checksum
      result.checksum += row.age
      result.checksum += row.shard
      result.checksum += int64(row.score * 1000.0)
      result.checksum += int64(row.ratio * 1000.0)
      result.checksum += row.tag.len
      result.checksum += row.balance

  result.label = "squeal binary typed"
  result.elapsedMs = elapsedMs(start)

proc printResult(result: BenchResult) =
  let rowsPerSec =
    if result.elapsedMs == 0.0:
      0.0
    else:
      float(result.rows) / (result.elapsedMs / 1000.0)
  echo result.label
  echo "  rows:      ", result.rows
  echo "  checksum:  ", result.checksum
  echo "  elapsed:   ", formatFloat(result.elapsedMs, ffDecimal, 3), " ms"
  echo "  rows/sec:  ", formatFloat(rowsPerSec, ffDecimal, 0)

proc throughput(bench: BenchResult): float =
  if bench.elapsedMs == 0.0:
    0.0
  else:
    float(bench.rows) / (bench.elapsedMs / 1000.0)

when isMainModule:
  let
    rowCount = envInt("SQUEAL_BENCH_ROWS", 40_000)
    iterations = envInt("SQUEAL_BENCH_ITERS", 200)

  let db = openBenchDb()
  try:
    setupBenchData(db, rowCount)

    echo "PostgreSQL fetch benchmark"
    echo "  rows/iteration: ", rowCount
    echo "  iterations:     ", iterations
    echo ""

    let dbConnector = benchDbConnector(db, iterations)
    let squeal = benchSqueal(db, iterations)

    printResult(dbConnector)
    printResult(squeal)

    if dbConnector.checksum != squeal.checksum:
      quit("benchmark checksum mismatch", 1)

    let ratio =
      if dbConnector.elapsedMs == 0.0:
        0.0
      else:
        throughput(squeal) / throughput(dbConnector)
    echo ""
    echo "squeal/db_connector throughput ratio: ", formatFloat(ratio, ffDecimal, 2), "x"
  finally:
    db.close()
