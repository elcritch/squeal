# squeal

Squeal is an experimental PostgreSQL binary query layer for Nim. It builds on
`db_connector/db_postgres` and `libpq`, then adds explicit binary parameters,
binary result decoding, and typed row mapping.

Current benchmark from `nim testPostgres` on a local PostgreSQL instance:

```text
db_connector text Row:  ~1.1M rows/sec
squeal binary typed:    ~1.7M rows/sec
ratio:                  ~1.5x
```

Treat this as a directional benchmark, not a universal result. It fetches
1,000,000 simple rows (`int8`, `text`, `bool`) and compares `db_connector`
text rows with Squeal binary typed rows.

## Requirements

Install dependencies with Atlas:

```sh
atlas install
```

Squeal currently uses `libpq` through `deps/db_connector`, so PostgreSQL client
libraries must be installed.

Examples:

```sh
# macOS
brew install postgresql

# Ubuntu/Debian
sudo apt-get install postgresql postgresql-client libpq-dev
```

## How It Relates To db_connector

Squeal roughly follows `db_connector`:

- It re-exports `db_connector/db_common` and `db_connector/db_postgres`.
- `DbConn`, `SqlQuery`, `Row`, `DbError`, `open`, `close`, `sql"..."`, and the
  existing text APIs are still available.
- Existing `db_connector` code can keep using `db.exec`, `db.getAllRows`,
  `db.rows`, and related text APIs.

The important differences are:

- Binary Squeal APIs use PostgreSQL-native `$1`, `$2`, ... placeholders.
- `db_connector` text substitution uses `?`; do not use `?` with binary APIs.
- Squeal binary APIs send parameters through `PQexecParams` /
  `PQsendQueryParams`, not SQL string interpolation.
- Typed result APIs require selected columns to have supported binary decoders.
- `Row = seq[string]` can hold copied binary bytes, but those bytes are not text.
- `DbConn` / `PGconn` should be owned by one thread at a time. Use one
  connection per thread or a pool that checks out a connection exclusively.

## Opening A Connection

Use the normal `db_connector` PostgreSQL `open` shape:

```nim
import squeal

let db = open("127.0.0.1:5432", "postgres", "", "example")
defer: db.close()
```

## Executing Binary Parameters

Use `execBinary` for statements with binary encoded parameters:

```nim
import squeal

let db = open("127.0.0.1:5432", "postgres", "", "example")
defer: db.close()

db.exec(sql"""
  create table if not exists person(
    id bigserial primary key,
    name text not null,
    active bool not null
  )
""")

db.execBinary(
  sql"insert into person(name, active) values ($1, $2)",
  "Ada",
  true,
)
```

## Typed Rows

Define an object whose field names match the selected column names. Squeal uses
Nim `fieldPairs` to populate the object directly.

```nim
import squeal

type Person = object
  id: int64
  name: string
  active: bool

let people = getAll[Person](
  db,
  sql"""
    select id, name, active
    from person
    where active = $1
    order by id
  """,
  true,
)

for person in people:
  echo person.id, " ", person.name
```

The typed API supports `bool`, `int16`, `int32`, `int64`, `int`, `float32`,
`float64`, `string`, `seq[byte]`, and `Option[T]` for nullable values.

## Returning IDs

PostgreSQL `returning` works naturally with typed rows:

```nim
import squeal

type IdRow = object
  id: int64

let id = getAll[IdRow](
  db,
  sql"insert into person(name, active) values ($1, $2) returning id",
  "Grace",
  true,
)[0].id
```

## Nullable Values

Use `Option[T]` for nullable result columns:

```nim
import std/options
import squeal

type OptionalEmail = object
  email: Option[string]

let row = getAll[OptionalEmail](
  db,
  sql"select null::text as email",
)[0]

doAssert row.email.isNone
```

For nullable parameters, pass `none(T)` or `pgNull(T)`:

```nim
import std/options
import squeal

db.execBinary(
  sql"insert into profile(display_name, bio) values ($1, $2)",
  "Ada",
  none(string),
)

db.execBinary(
  sql"insert into profile(display_name, bio) values ($1, $2)",
  "Grace",
  pgNull(string),
)
```

## bytea

Use `seq[byte]` for `bytea` values:

```nim
import squeal

type BlobRow = object
  payload: seq[byte]

let payload = @[byte 0, 1, 2, 250, 255]

db.execBinary(
  sql"insert into artifact(payload) values ($1)",
  payload,
)

let row = getAll[BlobRow](db, sql"select payload from artifact limit 1")[0]
doAssert row.payload == payload
```

## Raw Binary Rows

`getAllBinaryRows` copies raw binary column bytes into `Row`. This is useful for
inspection, but remember the strings contain binary data, not text.

```nim
import squeal

let rows = db.getAllBinaryRows(sql"select $1::int4 as n", int32(0x01020304))
doAssert rows[0][0] == "\x01\x02\x03\x04"
```

For per-column metadata and typed access inside an iterator, use
`instantBinaryRows`:

```nim
import squeal

for row in instantBinaryRows(db, sql"select $1::int4 as n", int32(42)):
  doAssert row.len == 1
  doAssert row.format(0) == pgBinary
  doAssert row.oid(0) == pgInt4Oid
  doAssert row.get(0, int32) == 42
```

## Streaming Typed Rows

Use `rows[T]` when you want to iterate without building the final result sequence
yourself:

```nim
import squeal

type Person = object
  id: int64
  name: string
  active: bool

for person in rows[Person](
  db,
  sql"select id, name, active from person where active = $1",
  true,
):
  echo person
```

## Threading

`libpq` is thread-safe, but a single `PGconn` must not be manipulated by
multiple threads at the same time. In Squeal terms:

- Use one `DbConn` per thread, or
- Use a connection pool that checks out each `DbConn` exclusively, or
- Protect a shared `DbConn` with a mutex if you accept serialized queries.

The integration tests include an explicit threaded test with one connection per
worker thread.

## Tests

Run unit tests:

```sh
nim test
```

Run PostgreSQL integration tests and the benchmark. This task starts a managed
PostgreSQL instance under `tests/postgrescache/`:

```sh
nim testPostgres
```

Run only the benchmark:

```sh
nim benchmarkPostgres
```

Useful environment variables:

- `SQUEAL_PGDATA`: data directory for the managed PostgreSQL instance.
- `SQUEAL_PG_HOST`: default `127.0.0.1`.
- `SQUEAL_PG_PORT`: default `55432`.
- `SQUEAL_PG_USER`: default `$USER`.
- `SQUEAL_PG_DATABASE`: default depends on the task.
- `SQUEAL_BENCH_ROWS`: default `10000`.
- `SQUEAL_BENCH_ITERS`: default `100`.
