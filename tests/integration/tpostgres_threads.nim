import std/[os, unittest]

import squeal

type
  CountRow = object
    count: int64

  SumRow = object
    total: int64

  WorkerArg = object
    host: string
    user: string
    password: string
    database: string
    workerId: int32
    iterations: int32

proc env(name, defaultValue: string): string =
  result = getEnv(name)
  if result.len == 0:
    result = defaultValue

proc testConnectionString(): tuple[host, user, password, database: string] =
  (
    host: env("SQUEAL_PG_HOST", "127.0.0.1") & ":" & env("SQUEAL_PG_PORT", "55432"),
    user: env("SQUEAL_PG_USER", getEnv("USER")),
    password: env("SQUEAL_PG_PASSWORD", ""),
    database: env("SQUEAL_PG_DATABASE", "squeal_test"),
  )

proc openTestDb(): DbConn =
  let conn = testConnectionString()
  open(conn.host, conn.user, conn.password, conn.database)

proc workerOpen(arg: WorkerArg): DbConn =
  open(arg.host, arg.user, arg.password, arg.database)

proc execSql(db: DbConn, query: string) =
  db.exec(SqlQuery(query))

proc resetSchema(db: DbConn) =
  db.execSql("set client_min_messages = warning")
  db.execSql("drop table if exists threaded_event cascade")
  db.execSql(
    """
      create table threaded_event(
        id bigserial primary key,
        worker int4 not null,
        seq int4 not null,
        label text not null,
        value int8 not null,
        unique(worker, seq)
      )
    """
  )

proc insertWorker(arg: WorkerArg) {.thread.} =
  let db = workerOpen(arg)
  try:
    for i in 0'i32 ..< arg.iterations:
      db.execBinary(
        sql"""
          insert into threaded_event(worker, seq, label, value)
          values ($1, $2, $3, $4)
        """,
        arg.workerId,
        i,
        "worker-" & $arg.workerId,
        int64(arg.workerId) * 1_000_000'i64 + int64(i),
      )

    let count =
      getAll[CountRow](
        db,
        sql"select count(*)::int8 as count from threaded_event where worker = $1",
        arg.workerId,
      )[0].count
    doAssert count == int64(arg.iterations)
  finally:
    db.close()

proc stressWorker(arg: WorkerArg) {.thread.} =
  let db = workerOpen(arg)
  try:
    for i in 0'i32 ..< arg.iterations:
      db.execBinary(
        sql"""
          insert into threaded_event(worker, seq, label, value)
          values ($1, $2, $3, $4)
        """,
        arg.workerId,
        i,
        "stress-" & $arg.workerId,
        int64(arg.workerId) * 1_000_000'i64 + int64(i),
      )

      let count =
        getAll[CountRow](
          db,
          sql"""
            select count(*)::int8 as count
            from threaded_event
            where worker = $1 and seq <= $2
          """,
          arg.workerId,
          i,
        )[0].count
      doAssert count == int64(i) + 1

      if (i mod 10) == 0:
        let total =
          getAll[SumRow](
            db,
            sql"""
              select coalesce(sum(value), 0)::int8 as total
              from threaded_event
              where worker = $1
            """,
            arg.workerId,
          )[0].total
        doAssert total >= int64(arg.workerId) * 1_000_000'i64
  finally:
    db.close()

suite "squeal PostgreSQL threading integration":
  var db: DbConn

  setup:
    db = openTestDb()
    resetSchema(db)

  teardown:
    if db != nil:
      db.close()

  test "supports one libpq connection per thread":
    const
      workerCount = 4
      iterations = 25'i32

    let conn = testConnectionString()
    var threads: array[workerCount, Thread[WorkerArg]]
    var args: array[workerCount, WorkerArg]

    for i in 0 ..< workerCount:
      args[i] = WorkerArg(
        host: conn.host,
        user: conn.user,
        password: conn.password,
        database: conn.database,
        workerId: int32(i),
        iterations: iterations,
      )
      createThread(threads[i], insertWorker, args[i])

    joinThreads(threads)

    check getAll[CountRow](db, sql"select count(*)::int8 as count from threaded_event")[
      0
    ].count == int64(workerCount) * int64(iterations)

  test "stress tests threaded binary reads and writes":
    const
      workerCount = 4
      iterations = 1_000'i32

    let conn = testConnectionString()
    var threads: array[workerCount, Thread[WorkerArg]]
    var args: array[workerCount, WorkerArg]

    for i in 0 ..< workerCount:
      args[i] = WorkerArg(
        host: conn.host,
        user: conn.user,
        password: conn.password,
        database: conn.database,
        workerId: int32(i),
        iterations: iterations,
      )
      createThread(threads[i], stressWorker, args[i])

    joinThreads(threads)

    check getAll[CountRow](db, sql"select count(*)::int8 as count from threaded_event")[
      0
    ].count == int64(workerCount) * int64(iterations)

    let total =
      getAll[SumRow](db, sql"select sum(value)::int8 as total from threaded_event")[0].total
    check total > 0
