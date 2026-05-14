# PostgreSQL Binary Protocol Support

This note summarizes how PostgreSQL binary protocol support could be added as
an opt-in path alongside the existing text-oriented `db_connector` PostgreSQL
API.

## Context

The current PostgreSQL connector is built on libpq. It does not implement the
frontend/backend wire protocol directly, and it does not need to in order to
use binary values. libpq already exposes the relevant extended-query knobs:

- `PQexecParams` and `PQexecPrepared` accept parameter OIDs, parameter byte
  lengths, parameter format codes, and a result format code.
- Format code `0` means text and format code `1` means binary.
- Binary result data must be read with `PQgetvalue` plus `PQgetlength` and
  `PQgetisnull`; treating it as a C string is incorrect because binary values
  may contain `NUL` bytes.
- Integer fields in the PostgreSQL protocol are network byte order.

Current `db_connector/db_postgres.nim` behavior is string-first:

- `Row = seq[string]`.
- `InstantRow[]` returns `$PQgetvalue(...)`.
- Normal `?` substitution formats arguments into SQL text.
- Prepared statements call `PQexecPrepared`, but pass `nil` for
  `paramLengths` and `paramFormats`, and pass `0` for `resultFormat`.
- The low-level bindings in `postgres.nim` already include `PQgetlength`,
  `PQgetisnull`, `PQfformat`, `PQftype`, `PQbinaryTuples`,
  `PQsendQueryParams`, and `PQsendQueryPrepared`.

The missing piece is a typed codec layer above libpq.

References:

- PostgreSQL protocol overview: <https://www.postgresql.org/docs/current/protocol-overview.html>
- PostgreSQL libpq command execution: <https://www.postgresql.org/docs/current/libpq-exec.html>
- PostgreSQL protocol message formats: <https://www.postgresql.org/docs/current/protocol-message-types.html>

## Design Goal

Binary support should be additive and explicit:

- Keep existing `Row`, `InstantRow`, `getValue`, `getRow`, `getAllRows`, and
  `fastRows` text behavior unchanged.
- Add PostgreSQL-specific opt-in APIs for binary rows and typed decoding.
- Prefer compile-time generated serializers and deserializers, similar to
  `deps/msgpack4nim`, instead of runtime reflection tables.
- Make binary mode useful for high-throughput typed reads and writes, not just
  for transporting opaque byte strings.

## API Shape

A minimal foundation:

```nim
type
  PgFormat* = enum
    pgText = 0
    pgBinary = 1

  PgParam* = object
    oid*: Oid
    format*: int32
    data*: string
    isNull*: bool

  PgValue* = object
    oid*: Oid
    format*: int32
    data*: ptr UncheckedArray[byte]
    len*: int32
    isNull*: bool
```

Low-level binary row APIs:

```nim
iterator instantBinaryRows*(db: DbConn, query: SqlQuery,
                            args: varargs[typed]): InstantRow

iterator fastBinaryRows*(db: DbConn, query: SqlQuery,
                         args: varargs[typed]): Row

proc getAllBinaryRows*(db: DbConn, query: SqlQuery,
                       args: varargs[typed]): seq[Row]
```

`InstantRow` should get PostgreSQL-specific raw accessors:

```nim
proc isNull*(row: InstantRow, col: int): bool
proc oid*(row: InstantRow, col: int): Oid
proc format*(row: InstantRow, col: int): PgFormat
proc byteLen*(row: InstantRow, col: int): int
proc rawValue*(row: InstantRow, col: int): PgValue
proc get*[T](row: InstantRow, col: int, typedesc[T]): T
```

`Row = seq[string]` can technically carry binary bytes because Nim strings are
byte sequences, but that is semantically different from text rows. Existing
`getAllRows` should not silently start returning binary strings. A distinct
`getAllBinaryRows` name or explicit `format = pgBinary` overload avoids that
ambiguity.

Typed APIs:

```nim
proc getAll*[T: object](db: DbConn, query: SqlQuery,
                        args: varargs[typed]): seq[T]

iterator rows*[T: object](db: DbConn, query: SqlQuery,
                          args: varargs[typed]): T

proc execBinary*(db: DbConn, query: SqlQuery, args: varargs[typed])
```

The typed path is where binary mode pays off. It avoids string parsing and can
generate direct object population code at compile time.

## Codec Model

Use overloads as the extension mechanism:

```nim
proc pgOid*(T: typedesc[int32]): Oid = 23
proc pgEncode*(value: int32): string
proc pgDecode*(T: typedesc[int32], value: PgValue): int32
```

Initial scalar codec set:

- `bool` using PostgreSQL OID `16`.
- `int16`, `int32`, `int64` using OIDs `21`, `23`, `20`.
- `float32`, `float64` using OIDs `700`, `701`.
- `string` for `text`, `varchar`, `bpchar`, and related text OIDs.
- `seq[byte]` or a small `PgBytea` type for `bytea`.
- `Uuid` if the project has or adds a UUID type.
- `DateTime` or PostgreSQL-specific date/time wrappers after deciding exact
  epoch and timezone semantics.

The implementation should validate both expected format and expected OID when
decoding. If PostgreSQL returns text despite a binary request, or returns an
unexpected OID, the typed decode should raise a connector error rather than
producing a wrong value.

## Type-Level Metaprogramming

The `msgpack4nim` pattern to copy is the `fields` and `fieldPairs` style:

```nim
for field in fields(value):
  encodeField(field)

for fieldName, fieldValue in fieldPairs(value):
  encodeNamedField(fieldName, fieldValue)
```

For PostgreSQL, object decoding can be generated as direct field assignments:

```nim
for fieldName, fieldValue in fieldPairs(result):
  fieldValue = row.get(typeof(fieldValue), columnIndexFor(fieldName))
```

Useful compile-time features:

- Generate a field-to-column mapping once per object type.
- Support field pragmas or templates for database column names.
- Support omitted fields and default values explicitly, not accidentally.
- Emit a compile-time error if a field type has no binary decoder.
- Generate direct calls to `pgDecode(T, value)`, allowing normal Nim overload
  resolution to choose custom codecs.

Potential field annotation shape:

```nim
type UserRow = object
  id {.pgName: "user_id".}: int64
  email: string
  active: bool
```

If custom pragmas are too much for the first pass, start with exact field name
to column name matching.

## Parameter Encoding

Binary parameters need an owned buffer per argument. The arrays passed to libpq
must point into storage that lives until the libpq call returns.

Internal builder shape:

```nim
type PgParamSet = object
  oids: seq[Oid]
  values: seq[cstring]
  lengths: seq[int32]
  formats: seq[int32]
  storage: seq[string]
```

For each argument:

- `NULL` values get `values[i] = nil`.
- Binary values set `formats[i] = 1`, `lengths[i] = data.len`, and `oids[i]`
  from `pgOid(typeof(arg))`.
- Text fallback values can set `formats[i] = 0`.

Prepared statements should support binary params through `PQexecPrepared`.
Unprepared binary queries should use `PQexecParams`, not string substitution.

## Result Format Constraints

libpq's `PQexecParams` and `PQexecPrepared` expose a single `resultFormat`
integer, not a per-column result format list. That means binary mode requests
binary for all result columns.

Implications:

- Typed binary result APIs should require every selected column to have a
  supported decoder.
- Raw `InstantRow` binary access is useful because it can expose unsupported
  binary columns without decoding them.
- Existing text APIs remain the fallback for heterogeneous or unsupported
  result sets.
- Mixed text/binary result columns would require dropping below these libpq
  convenience functions into lower-level protocol message construction, which
  is not worth doing initially.

## Row And InstantRow Compatibility

`InstantRow` can support binary protocol cleanly because it already wraps
`PGresult`. New methods can expose raw value metadata and typed access.

`Row` can support binary protocol mechanically by copying raw bytes into each
string slot. This should be opt-in and clearly named because users will no
longer receive textual values. For example, an `int4` column would become four
big-endian bytes, not `"123"`.

Recommended rule:

- Existing `row[col]` and `getAllRows` remain text-oriented.
- Binary rows use `fastBinaryRows`, `instantBinaryRows`, or an explicit
  `format = pgBinary` argument.
- `InstantRow.get[T](col)` is the preferred typed access path.

## Relationship To db_connector APIs

Useful binary support necessarily deviates from the portable `db_connector`
surface. The shared API is text-based and does not model:

- Column OIDs.
- Per-column format codes.
- Raw byte lengths.
- Null state independent from empty string.
- Typed binary decoders.

The pragmatic approach is to keep the portable API unchanged and add
PostgreSQL-specific APIs beside it. Basic binary row transport can be exposed
with small overloads, while high-performance object decoding should live in a
PostgreSQL-specific layer.

## Implementation Phases

1. Add raw binary query support.
   - Build `PgParamSet`.
   - Call `PQexecParams` and `PQexecPrepared` with binary parameter arrays.
   - Request `resultFormat = 1`.
   - Add `InstantRow` raw accessors using `PQgetisnull`, `PQgetlength`,
     `PQgetvalue`, `PQftype`, and `PQfformat`.

2. Add scalar codecs.
   - Implement integer, float, bool, text, and bytea first.
   - Add OID and format validation.
   - Add focused tests that compare text and binary query results.

3. Add typed row decoding.
   - Implement `row.get[T](col)`.
   - Implement `rows[T: object]` using compile-time `fieldPairs`.
   - Start with exact field-to-column name matching.

4. Add prepared statement support.
   - Preserve existing `SqlPrepared` behavior.
   - Add binary execution variants for prepared statements.
   - Consider a richer prepared statement type later if parameter OIDs and
     result schemas need to be cached.

5. Expand supported types.
   - Add UUID, date/time, JSON/JSONB, numeric, arrays, ranges, and composites
     after the core path is stable.
   - Treat complex PostgreSQL binary formats carefully because PostgreSQL
     documents them as type-specific and less portable than text.

## Open Questions

- Should binary APIs live in `db_postgres.nim` or a separate
  `db_postgres_binary.nim` module?
- Should binary `Row` be represented as `seq[string]`, `seq[PgValue]`, or a new
  `BinaryRow` type?
- How should nulls map into typed Nim fields: `Option[T]`, default values, or
  connector errors?
- Should object mapping be positional, name-based, or configurable per call?
- Should text fallback be allowed per parameter, or should binary APIs require
  every argument to have a binary encoder?

## Recommendation

Start with `InstantRow` binary support and scalar typed decoding. That provides
the core safety and performance primitives without changing existing behavior.
Then layer object decoding on top using compile-time field iteration, following
the same general design style that makes `msgpack4nim` fast.

Avoid changing the meaning of existing `Row` APIs. If binary `Row` support is
needed, expose it under explicit names so users know the strings contain raw
PostgreSQL binary values rather than text.
