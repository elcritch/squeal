import std/[math, options, unittest]

import squeal

type UserRow = object
  id: int64
  email: string
  active: bool

static:
  doAssert compiles(
    block:
      let db: DbConn = nil
      db.execBinary(
        sql"insert into users(id, email, active) values ($1, $2, $3)",
        1'i64,
        "a@example.test",
        true,
      )
  )

  doAssert compiles(
    block:
      let db: DbConn = nil
      discard db.getAllBinaryRows(sql"select $1::int8", 1'i64)
  )

  doAssert compiles(
    block:
      let db: DbConn = nil
      discard getAll[UserRow](
        db, sql"select id, email, active from users where id = $1", 1'i64
      )
  )

proc pgValue(oid: Oid, data: string): PgValue =
  PgValue(
    oid: oid,
    format: int32(pgBinary),
    data: cast[ptr UncheckedArray[byte]](data.cstring),
    len: int32(data.len),
    isNull: false,
  )

suite "squeal PostgreSQL binary codecs":
  test "encodes integers in network byte order":
    check pgEncode(int16(0x0102)) == "\x01\x02"
    check pgEncode(int32(0x01020304)) == "\x01\x02\x03\x04"
    check pgEncode(int64(0x0102030405060708'i64)) == "\x01\x02\x03\x04\x05\x06\x07\x08"

  test "decodes integer values":
    var int2 = pgEncode(int16(-2))
    var int4 = pgEncode(int32(-3))
    var int8 = pgEncode(int64(-4))

    check pgDecode(int16, pgValue(pgInt2Oid, int2)) == -2'i16
    check pgDecode(int32, pgValue(pgInt4Oid, int4)) == -3'i32
    check pgDecode(int64, pgValue(pgInt8Oid, int8)) == -4'i64

  test "encodes and decodes bool":
    var yes = pgEncode(true)
    var no = pgEncode(false)

    check yes == "\x01"
    check no == "\x00"
    check pgDecode(bool, pgValue(pgBoolOid, yes)) == true
    check pgDecode(bool, pgValue(pgBoolOid, no)) == false

  test "round-trips float bits":
    var f4 = pgEncode(float32(12.5))
    var f8 = pgEncode(42.25)

    check pgDecode(float32, pgValue(pgFloat4Oid, f4)) == float32(12.5)
    check almostEqual(pgDecode(float64, pgValue(pgFloat8Oid, f8)), 42.25)

  test "round-trips text and bytea payloads":
    var text = pgEncode("a\0b")
    var bytes = pgEncode(@[byte 0, 1, 255])

    check pgDecode(string, pgValue(pgTextOid, text)) == "a\0b"
    check pgDecode(seq[byte], pgValue(pgByteaOid, bytes)) == @[byte 0, 1, 255]

  test "decodes option nulls":
    let nullText =
      PgValue(oid: pgTextOid, format: int32(pgBinary), data: nil, len: 0, isNull: true)

    check pgDecode(Option[string], nullText).isNone
