import std/[os, options, unittest]

import squeal

type
  IdRow = object
    id: int64

  CountRow = object
    count: int64

  ThreadSummary = object
    id: int64
    name: string
    views: int32
    active: bool

  ThreadName = object
    id: int64
    name: string

  ThreadCount = object
    thread: int64
    count: int64

  PersonStatus = object
    name: string
    email: string
    status: string
    ban: string

  SessionUser = object
    userid: int64

  AntibotComputed = object
    doubled: string
    marker: int32

  AuthorName = object
    author: int64
    name: string

  OptionalText = object
    value: Option[string]

  BlobRow = object
    payload: seq[byte]

proc env(name, defaultValue: string): string =
  result = getEnv(name)
  if result.len == 0:
    result = defaultValue

proc openTestDb(): DbConn =
  open(
    env("SQUEAL_PG_HOST", "127.0.0.1") & ":" & env("SQUEAL_PG_PORT", "55432"),
    env("SQUEAL_PG_USER", getEnv("USER")),
    env("SQUEAL_PG_PASSWORD", ""),
    env("SQUEAL_PG_DATABASE", "squeal_test"),
  )

proc execSql(db: DbConn, query: string) =
  db.exec(SqlQuery(query))

proc seedForum(db: DbConn): tuple[threadId, personId, postId: int64] =
  result.threadId =
    getAll[IdRow](
      db,
      sql"insert into thread(name, views) values ($1, $2) returning id",
      "first thread",
      int32(0),
    )[0].id

  result.personId =
    getAll[IdRow](
      db,
      sql"""
        insert into person(name, password, email, salt, status)
        values ($1, $2, $3, $4, $5) returning id
      """,
      "me",
      "mypw",
      "some@body.com",
      "pepper",
      "EmailUnconfirmed",
    )[0].id

  result.postId =
    getAll[IdRow](
      db,
      sql"""
        insert into post(author, ip, header, content, thread)
        values ($1, $2::inet, $3, $4, $5) returning id
      """,
      result.personId,
      "127.0.0.1",
      "hello",
      "content",
      result.threadId,
    )[0].id

proc resetSchema(db: DbConn) =
  db.execSql("set client_min_messages = warning")
  db.execSql("drop table if exists session cascade")
  db.execSql("drop table if exists post cascade")
  db.execSql("drop table if exists person cascade")
  db.execSql("drop table if exists thread cascade")
  db.execSql("drop table if exists antibot cascade")
  db.execSql("drop table if exists artifact cascade")

  db.execSql(
    """
      create table thread(
        id bigserial primary key,
        name text not null unique,
        views int4 not null,
        modified timestamp not null default now()
      )
    """
  )

  db.execSql(
    """
      create table person(
        id bigserial primary key,
        name text not null unique,
        password text not null,
        email text not null,
        creation timestamp not null default now(),
        salt text not null,
        status text not null,
        lastOnline timestamp not null default now(),
        ban text not null default ''
      )
    """
  )

  db.execSql(
    """
      create table post(
        id bigserial primary key,
        author int8 not null references person(id),
        ip inet not null,
        header text not null,
        content text not null,
        thread int8 not null references thread(id),
        creation timestamp not null default now()
      )
    """
  )

  db.execSql(
    """
      create table session(
        id bigserial primary key,
        ip inet not null,
        password text not null,
        userid int8 not null references person(id),
        lastModified timestamp not null default now()
      )
    """
  )

  db.execSql(
    """
      create table antibot(
        id bigserial primary key,
        ip inet not null,
        answer text not null,
        created timestamp not null default now()
      )
    """
  )

  db.execSql(
    """
      create table artifact(
        id bigserial primary key,
        payload bytea not null
      )
    """
  )

  db.execSql("create index PersonStatusIdx on person(status)")
  db.execSql("create index PostByAuthorIdx on post(thread, author)")

suite "squeal PostgreSQL binary integration":
  var db: DbConn

  setup:
    db = openTestDb()
    resetSchema(db)

  teardown:
    if db != nil:
      db.close()

  test "runs Ormin-style basic SQL checks through binary params and rows":
    let (threadId, personId, postId) = seedForum(db)

    check postId > 0

    db.execBinary(
      sql"insert into session(ip, password, userid) values ($1::inet, $2, $3)",
      "127.0.0.1",
      "mypw",
      personId,
    )
    db.execBinary(
      sql"insert into antibot(ip, answer) values ($1::inet, $2)", "127.0.0.1", "dunno"
    )

    check getAll[CountRow](db, sql"select count(*)::int8 as count from person")[0].count ==
      1
    check getAll[CountRow](db, sql"select count(*)::int8 as count from post")[0].count ==
      1
    check getAll[CountRow](db, sql"select count(*)::int8 as count from thread")[0].count ==
      1

    let thread = getAll[ThreadSummary](
      db,
      sql"""
        select id, name, views, views >= 0 as active
        from thread where id = $1
      """,
      threadId,
    )[0]
    check thread ==
      ThreadSummary(id: threadId, name: "first thread", views: 0, active: true)

    db.execBinary(
      sql"update thread set views = views + $1 where id = $2", int32(1), threadId
    )
    check getAll[ThreadSummary](
      db,
      sql"""
        select id, name, views, views > 0 as active
        from thread where id = $1
      """,
      threadId,
    )[0].views == 1

    check getAll[CountRow](
      db,
      sql"""
        select count(*)::int8 as count
        from post p, person u
        where u.id = p.author and p.thread = $1
      """,
      threadId,
    )[0].count == 1

    check getAll[CountRow](
      db,
      sql"""
        select count(*)::int8 as count
        from thread
        where id in (
          select thread from post
          where author = $1 and post.id in (select min(id) from post group by thread)
        )
      """,
      personId,
    )[0].count == 1

    db.execBinary(
      sql"update person set status = $1, ban = $2 where name = $3", "Active", "", "me"
    )
    let status = getAll[PersonStatus](
      db, sql"select name, email, status, ban from person where id = $1", personId
    )[0]
    check status ==
      PersonStatus(name: "me", email: "some@body.com", status: "Active", ban: "")

    db.execBinary(
      sql"delete from session where ip = $1::inet and password = $2",
      "127.0.0.1",
      "mypw",
    )
    check getAll[CountRow](db, sql"select count(*)::int8 as count from session")[0].count ==
      0

  test "copies raw binary rows, NULL options, and bytea":
    let rawRows = db.getAllBinaryRows(sql"select $1::int4 as n", int32(0x01020304))
    check rawRows.len == 1
    check rawRows[0].len == 1
    check rawRows[0][0] == "\x01\x02\x03\x04"

    check getAll[OptionalText](db, sql"select null::text as value")[0].value.isNone
    check getAll[OptionalText](db, sql"select $1::text as value", "present")[0].value.get ==
      "present"

    let payload = @[byte 0, 1, 2, 250, 255]
    discard getAll[IdRow](
      db, sql"insert into artifact(payload) values ($1) returning id", payload
    )
    check getAll[BlobRow](db, sql"select payload from artifact")[0].payload == payload

  test "covers Ormin-style ordering, limits, empty results, and expressions":
    let (threadId, personId, _) = seedForum(db)
    let secondThread =
      getAll[IdRow](
        db,
        sql"insert into thread(name, views) values ($1, $2) returning id",
        "second thread",
        int32(2),
      )[0].id
    let thirdThread =
      getAll[IdRow](
        db,
        sql"insert into thread(name, views) values ($1, $2) returning id",
        "third thread",
        int32(3),
      )[0].id

    let paged = getAll[ThreadName](
      db,
      sql"""
        select id, name
        from thread
        where id in (
          select thread from post
          where author in (
            select id from person
            where status not in ($1) or id = $2
          )
          union all
          select id from thread where id in ($3, $4)
        )
        order by id desc
        limit $5
        offset $6
      """,
      "Spammer",
      personId,
      secondThread,
      thirdThread,
      int64(2),
      int64(1),
    )
    check paged ==
      @[
        ThreadName(id: secondThread, name: "second thread"),
        ThreadName(id: threadId, name: "first thread"),
      ]

    check getAll[IdRow](db, sql"select id from thread where id = $1", int64(-1)).len == 0

    db.execBinary(
      sql"insert into antibot(ip, answer) values ($1::inet, $2)", "127.0.0.2", "dunno"
    )
    db.execBinary(
      sql"insert into antibot(ip, answer) values ($1::inet, $2)", "127.0.0.3", "things"
    )
    let computed = getAll[AntibotComputed](
      db,
      sql"""
        select answer || answer as doubled,
               (case when host(ip) = $1 then 0 else 1 end)::int4 as marker
        from antibot
        where answer like $2
        order by ip desc
        limit 1
      """,
      "hi",
      "%things%",
    )
    check computed == @[AntibotComputed(doubled: "thingsthings", marker: 1)]

  test "covers Ormin-style sessions, joins, grouped counts, and cleanup":
    let (threadId, personId, _) = seedForum(db)
    let orphanThread =
      getAll[IdRow](
        db,
        sql"insert into thread(name, views) values ($1, $2) returning id",
        "orphan",
        int32(0),
      )[0].id

    db.execBinary(
      sql"insert into session(ip, password, userid) values ($1::inet, $2, $3)",
      "127.0.0.1",
      "mypw",
      personId,
    )
    let sessionUsers = getAll[SessionUser](
      db,
      sql"select userid from session where ip = $1::inet and password = $2",
      "127.0.0.1",
      "mypw",
    )
    check sessionUsers == @[SessionUser(userid: personId)]

    db.execBinary(
      sql"update session set lastModified = now() where ip = $1::inet and password = $2",
      "127.0.0.1",
      "mypw",
    )
    check getAll[CountRow](
      db, sql"select count(*)::int8 as count from session where userid = $1", personId
    )[0].count == 1

    let joined = getAll[AuthorName](
      db,
      sql"""
        select p.author, u.name
        from post p
        join person u on p.author = u.id
        where p.thread = $1
        limit 1
      """,
      threadId,
    )
    check joined == @[AuthorName(author: personId, name: "me")]

    let grouped = getAll[ThreadCount](
      db,
      sql"""
        select thread, count(*)::int8 as count
        from post
        group by thread
        having count(*) > 0
        order by thread
      """,
    )
    check grouped == @[ThreadCount(thread: threadId, count: 1)]

    check getAll[CountRow](
      db,
      sql"""
        select count(*)::int8 as count
        from thread
        where id in (
          select thread from post
          where author = $1
            and post.id in (select min(id) from post group by thread)
        )
      """,
      personId,
    )[0].count == 1

    db.execBinary(sql"delete from thread where id not in (select thread from post)")
    check getAll[IdRow](db, sql"select id from thread where id = $1", orphanThread).len ==
      0
    check getAll[IdRow](db, sql"select id from thread where id = $1", threadId).len == 1
