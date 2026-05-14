import std/[monotimes, os, strutils, times]

import squeal

type
  BenchRow = object
    id: int64
    name: string
    active: bool

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
        active bool not null
      )
    """
  )
  db.execSql(
    "insert into squeal_bench(id, name, active) " &
      "select i::int8, 'name-' || i::text, (i % 2 = 0) " & "from generate_series(1, " &
      $rowCount & ") as i"
  )

proc benchDbConnector(db: DbConn, iterations: int): BenchResult =
  let start = getMonoTime()
  for _ in 0 ..< iterations:
    let rows = db.getAllRows(sql"select id, name, active from squeal_bench order by id")
    result.rows += rows.len
    for row in rows:
      result.checksum += parseInt(row[0])
      result.checksum += row[1].len
      if row[2] == "t":
        inc result.checksum

  result.label = "db_connector text Row"
  result.elapsedMs = elapsedMs(start)

proc benchSqueal(db: DbConn, iterations: int): BenchResult =
  let start = getMonoTime()
  for _ in 0 ..< iterations:
    let rows = getAll[BenchRow](
      db,
      sql"""
        select id, name, active
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

when isMainModule:
  let
    rowCount = envInt("SQUEAL_BENCH_ROWS", 10_000)
    iterations = envInt("SQUEAL_BENCH_ITERS", 100)

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
  finally:
    db.close()
