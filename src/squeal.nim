## PostgreSQL binary protocol helpers built on top of db_connector/libpq.
##
## Binary query APIs use PostgreSQL's native `$1`, `$2`, ... placeholders.
## The existing db_connector text APIs are re-exported unchanged.

import std/[macros, options]

import db_connector/db_common as dbcommon
import db_connector/db_postgres as pgdb
import db_connector/postgres

export dbcommon
export pgdb
export postgres

type
  PgFormat* = enum
    pgText = 0
    pgBinary = 1

  PgValue* = object
    oid*: Oid
    format*: int32
    data*: ptr UncheckedArray[byte]
    len*: int32
    isNull*: bool

  PgInstantRow* = object
    res: PPGresult

  PgNull*[T] = object

  PgParamSet = object
    oids: seq[Oid]
    values: seq[cstring]
    lengths: seq[int32]
    formats: seq[int32]
    storage: seq[string]
    nulls: seq[bool]

const
  pgBoolOid* = Oid(16)
  pgByteaOid* = Oid(17)
  pgInt8Oid* = Oid(20)
  pgInt2Oid* = Oid(21)
  pgInt4Oid* = Oid(23)
  pgTextOid* = Oid(25)
  pgFloat4Oid* = Oid(700)
  pgFloat8Oid* = Oid(701)
  pgBpcharOid* = Oid(1042)
  pgVarcharOid* = Oid(1043)

template pgNull*(T: typedesc): PgNull[T] =
  PgNull[T]()

proc fail(msg: string) {.noreturn.} =
  dbcommon.dbError(msg)

proc checkLen(value: PgValue, expected: int, typ: string) =
  if value.isNull:
    fail("cannot decode NULL as " & typ)
  if value.format != int32(pgBinary):
    fail("expected binary PostgreSQL value for " & typ)
  if value.len != expected:
    fail("expected " & $expected & " bytes for " & typ & ", got " & $value.len)

proc checkOid(value: PgValue, expected: openArray[Oid], typ: string) =
  for oid in expected:
    if value.oid == oid:
      return
  fail("unexpected PostgreSQL OID " & $value.oid & " for " & typ)

proc appendByte(result: var string, b: uint8) {.inline.} =
  result.add(char(b))

proc encodeU16(value: uint16): string =
  result = newStringOfCap(2)
  result.appendByte(uint8((value shr 8) and 0xff'u16))
  result.appendByte(uint8(value and 0xff'u16))

proc encodeU32(value: uint32): string =
  result = newStringOfCap(4)
  result.appendByte(uint8((value shr 24) and 0xff'u32))
  result.appendByte(uint8((value shr 16) and 0xff'u32))
  result.appendByte(uint8((value shr 8) and 0xff'u32))
  result.appendByte(uint8(value and 0xff'u32))

proc encodeU64(value: uint64): string =
  result = newStringOfCap(8)
  result.appendByte(uint8((value shr 56) and 0xff'u64))
  result.appendByte(uint8((value shr 48) and 0xff'u64))
  result.appendByte(uint8((value shr 40) and 0xff'u64))
  result.appendByte(uint8((value shr 32) and 0xff'u64))
  result.appendByte(uint8((value shr 24) and 0xff'u64))
  result.appendByte(uint8((value shr 16) and 0xff'u64))
  result.appendByte(uint8((value shr 8) and 0xff'u64))
  result.appendByte(uint8(value and 0xff'u64))

proc readU16(value: PgValue): uint16 =
  (uint16(value.data[0]) shl 8) or uint16(value.data[1])

proc readU32(value: PgValue): uint32 =
  (uint32(value.data[0]) shl 24) or (uint32(value.data[1]) shl 16) or
    (uint32(value.data[2]) shl 8) or uint32(value.data[3])

proc readU64(value: PgValue): uint64 =
  (uint64(value.data[0]) shl 56) or (uint64(value.data[1]) shl 48) or
    (uint64(value.data[2]) shl 40) or (uint64(value.data[3]) shl 32) or
    (uint64(value.data[4]) shl 24) or (uint64(value.data[5]) shl 16) or
    (uint64(value.data[6]) shl 8) or uint64(value.data[7])

proc bytesToString(data: ptr UncheckedArray[byte], len: int): string =
  result = newString(len)
  if len > 0:
    copyMem(addr result[0], data, len)

proc pgOid*(T: typedesc[bool]): Oid =
  pgBoolOid

proc pgOid*(T: typedesc[int16]): Oid =
  pgInt2Oid

proc pgOid*(T: typedesc[int32]): Oid =
  pgInt4Oid

proc pgOid*(T: typedesc[int64]): Oid =
  pgInt8Oid

proc pgOid*(T: typedesc[int]): Oid =
  pgInt8Oid

proc pgOid*(T: typedesc[float32]): Oid =
  pgFloat4Oid

proc pgOid*(T: typedesc[float64]): Oid =
  pgFloat8Oid

proc pgOid*(T: typedesc[string]): Oid =
  pgTextOid

proc pgOid*(T: typedesc[seq[byte]]): Oid =
  pgByteaOid

proc pgOid*[T](typ: typedesc[Option[T]]): Oid =
  pgOid(T)

proc pgEncode*(value: bool): string =
  if value: "\x01" else: "\x00"

proc pgEncode*(value: int16): string =
  encodeU16(cast[uint16](value))

proc pgEncode*(value: int32): string =
  encodeU32(cast[uint32](value))

proc pgEncode*(value: int64): string =
  encodeU64(cast[uint64](value))

proc pgEncode*(value: int): string =
  pgEncode(int64(value))

proc pgEncode*(value: float32): string =
  var bits: uint32
  copyMem(addr bits, unsafeAddr value, sizeof(bits))
  encodeU32(bits)

proc pgEncode*(value: float64): string =
  var bits: uint64
  copyMem(addr bits, unsafeAddr value, sizeof(bits))
  encodeU64(bits)

proc pgEncode*(value: string): string =
  value

proc pgEncode*(value: seq[byte]): string =
  result = newString(value.len)
  if value.len > 0:
    copyMem(addr result[0], unsafeAddr value[0], value.len)

proc pgDecode*(T: typedesc[bool], value: PgValue): bool =
  value.checkOid([pgBoolOid], "bool")
  value.checkLen(1, "bool")
  case value.data[0]
  of 0'u8:
    false
  of 1'u8:
    true
  else:
    fail("invalid PostgreSQL bool payload")

proc pgDecode*(T: typedesc[int16], value: PgValue): int16 =
  value.checkOid([pgInt2Oid], "int16")
  value.checkLen(2, "int16")
  cast[int16](readU16(value))

proc pgDecode*(T: typedesc[int32], value: PgValue): int32 =
  value.checkOid([pgInt4Oid], "int32")
  value.checkLen(4, "int32")
  cast[int32](readU32(value))

proc pgDecode*(T: typedesc[int64], value: PgValue): int64 =
  value.checkOid([pgInt8Oid], "int64")
  value.checkLen(8, "int64")
  cast[int64](readU64(value))

proc pgDecode*(T: typedesc[int], value: PgValue): int =
  when sizeof(int) == 8:
    int(pgDecode(int64, value))
  else:
    int(pgDecode(int32, value))

proc pgDecode*(T: typedesc[float32], value: PgValue): float32 =
  value.checkOid([pgFloat4Oid], "float32")
  value.checkLen(4, "float32")
  var bits = readU32(value)
  copyMem(addr result, addr bits, sizeof(result))

proc pgDecode*(T: typedesc[float64], value: PgValue): float64 =
  value.checkOid([pgFloat8Oid], "float64")
  value.checkLen(8, "float64")
  var bits = readU64(value)
  copyMem(addr result, addr bits, sizeof(result))

proc pgDecode*(T: typedesc[string], value: PgValue): string =
  value.checkOid([pgTextOid, pgVarcharOid, pgBpcharOid], "string")
  if value.isNull:
    fail("cannot decode NULL as string")
  if value.format != int32(pgBinary):
    fail("expected binary PostgreSQL value for string")
  bytesToString(value.data, int(value.len))

proc pgDecode*(T: typedesc[seq[byte]], value: PgValue): seq[byte] =
  value.checkOid([pgByteaOid], "seq[byte]")
  if value.isNull:
    fail("cannot decode NULL as seq[byte]")
  if value.format != int32(pgBinary):
    fail("expected binary PostgreSQL value for seq[byte]")
  result = newSeq[byte](int(value.len))
  if value.len > 0:
    copyMem(addr result[0], value.data, int(value.len))

proc pgDecode*[T](typ: typedesc[Option[T]], value: PgValue): Option[T] =
  if value.isNull:
    none(T)
  else:
    some(pgDecode(T, value))

proc addBinaryParam(params: var PgParamSet, oid: Oid, data: string) =
  params.oids.add(oid)
  params.storage.add(data)
  params.values.add(nil)
  params.lengths.add(int32(data.len))
  params.formats.add(int32(pgBinary))
  params.nulls.add(false)

proc addNullParam(params: var PgParamSet, oid: Oid) =
  params.oids.add(oid)
  params.storage.add("")
  params.values.add(nil)
  params.lengths.add(0)
  params.formats.add(int32(pgBinary))
  params.nulls.add(true)

proc addParam[T](params: var PgParamSet, value: Option[T]) =
  if value.isSome:
    params.addBinaryParam(pgOid(T), pgEncode(value.get()))
  else:
    params.addNullParam(pgOid(T))

proc addParam[T](params: var PgParamSet, value: PgNull[T]) =
  params.addNullParam(pgOid(T))

proc addParam[T](params: var PgParamSet, value: T) =
  params.addBinaryParam(pgOid(T), pgEncode(value))

macro pgParams(args: varargs[untyped]): untyped =
  let params = genSym(nskVar, "params")
  result = newStmtList()
  var body = newStmtList()
  body.add quote do:
    var `params`: PgParamSet
  for arg in args:
    body.add quote do:
      `params`.addParam(`arg`)
  body.add params
  result = nnkBlockExpr.newTree(newEmptyNode(), body)

proc oidPtr(params: var PgParamSet): POid =
  if params.oids.len == 0:
    nil
  else:
    cast[POid](addr params.oids[0])

proc valuePtr(params: var PgParamSet): cstringArray =
  if params.values.len == 0:
    nil
  else:
    cast[cstringArray](addr params.values[0])

proc intPtr(values: var seq[int32]): ptr int32 =
  if values.len == 0:
    nil
  else:
    addr values[0]

proc refreshValuePtrs(params: var PgParamSet) =
  for i in 0 ..< params.values.len:
    params.values[i] =
      if params.nulls[i]:
        nil
      else:
        params.storage[i].cstring

proc execParams(
    db: DbConn, query: SqlQuery, params: var PgParamSet, resultFormat: PgFormat
): PPGresult =
  params.refreshValuePtrs()
  pqexecParams(
    db,
    query.cstring,
    int32(params.oids.len),
    params.oidPtr(),
    params.valuePtr(),
    params.lengths.intPtr(),
    params.formats.intPtr(),
    int32(resultFormat),
  )

proc checkTuples(db: DbConn, res: PPGresult) =
  if pqResultStatus(res) != PGRES_TUPLES_OK:
    if not res.isNil:
      pqclear(res)
    pgdb.dbError(db)

proc checkCommand(db: DbConn, res: PPGresult) =
  if pqResultStatus(res) != PGRES_COMMAND_OK:
    if not res.isNil:
      pqclear(res)
    pgdb.dbError(db)

proc setBinaryRow(res: PPGresult, row: var Row, line, cols: int32) =
  for col in 0'i32 ..< cols:
    if pqgetisnull(res, line, col) == 1:
      row[int(col)] = ""
    else:
      let L = pqgetlength(res, line, col)
      row[int(col)] = bytesToString(
        cast[ptr UncheckedArray[byte]](pqgetvalue(res, line, col)), int(L)
      )

proc getAllBinaryRowsParams(
    db: DbConn, query: SqlQuery, params: var PgParamSet
): seq[Row] =
  let res = execParams(db, query, params, pgBinary)
  checkTuples(db, res)
  let rowCount = pqntuples(res)
  let colCount = pqnfields(res)
  result = newSeqOfCap[Row](int(rowCount))
  for line in 0'i32 ..< rowCount:
    var row = newSeq[string](int(colCount))
    setBinaryRow(res, row, line, colCount)
    result.add(row)
  pqclear(res)

template getAllBinaryRows*(
    db: DbConn, query: SqlQuery, args: varargs[untyped]
): seq[Row] =
  block:
    var params = pgParams(args)
    getAllBinaryRowsParams(db, query, params)

proc execBinaryParams(db: DbConn, query: SqlQuery, params: var PgParamSet) =
  let res = execParams(db, query, params, pgBinary)
  checkCommand(db, res)
  pqclear(res)

template execBinary*(db: DbConn, query: SqlQuery, args: varargs[untyped]) =
  block:
    var params = pgParams(args)
    execBinaryParams(db, query, params)

proc setupSingleBinaryQuery(db: DbConn, query: SqlQuery, params: var PgParamSet) =
  params.refreshValuePtrs()
  if pqsendQueryParams(
    db,
    query.cstring,
    int32(params.oids.len),
    params.oidPtr(),
    params.valuePtr(),
    params.lengths.intPtr(),
    params.formats.intPtr(),
    int32(pgBinary),
  ) != 1:
    pgdb.dbError(db)
  if pqSetSingleRowMode(db) != 1:
    pgdb.dbError(db)

template fetchBinaryRows(db: DbConn): untyped =
  var res: PPGresult = nil
  while true:
    res = pqgetresult(db)
    if res == nil:
      break
    let status = pqresultStatus(res)
    if status == PGRES_TUPLES_OK:
      discard
    elif status != PGRES_SINGLE_TUPLE:
      if not res.isNil:
        pqclear(res)
      pgdb.dbError(db)
    else:
      let colCount = pqnfields(res)
      var row = newSeq[string](int(colCount))
      setBinaryRow(res, row, 0, colCount)
      yield row
    pqclear(res)

iterator fastBinaryRowsParams(
    db: DbConn, query: SqlQuery, params: var PgParamSet
): Row =
  setupSingleBinaryQuery(db, query, params)
  fetchBinaryRows(db)

template fastBinaryRows*(db: DbConn, query: SqlQuery, args: varargs[untyped]): untyped =
  block:
    var params = pgParams(args)
    fastBinaryRowsParams(db, query, params)

template fetchBinaryInstantRows(db: DbConn): untyped =
  var res: PPGresult = nil
  while true:
    res = pqgetresult(db)
    if res == nil:
      break
    let status = pqresultStatus(res)
    if status == PGRES_TUPLES_OK:
      discard
    elif status != PGRES_SINGLE_TUPLE:
      if not res.isNil:
        pqclear(res)
      pgdb.dbError(db)
    else:
      yield PgInstantRow(res: res)
    pqclear(res)

iterator instantBinaryRowsParams(
    db: DbConn, query: SqlQuery, params: var PgParamSet
): PgInstantRow =
  setupSingleBinaryQuery(db, query, params)
  fetchBinaryInstantRows(db)

template instantBinaryRows*(
    db: DbConn, query: SqlQuery, args: varargs[untyped]
): untyped =
  block:
    var params = pgParams(args)
    instantBinaryRowsParams(db, query, params)

proc len*(row: PgInstantRow): int {.inline.} =
  int(pqnfields(row.res))

proc isNull*(row: PgInstantRow, col: int): bool {.inline.} =
  pqgetisnull(row.res, 0, int32(col)) == 1

proc oid*(row: PgInstantRow, col: int): Oid {.inline.} =
  pqftype(row.res, int32(col))

proc format*(row: PgInstantRow, col: int): PgFormat {.inline.} =
  PgFormat(pqfformat(row.res, int32(col)))

proc byteLen*(row: PgInstantRow, col: int): int {.inline.} =
  int(pqgetlength(row.res, 0, int32(col)))

proc rawValue*(row: PgInstantRow, col: int): PgValue =
  let isNull = row.isNull(col)
  PgValue(
    oid: row.oid(col),
    format: int32(row.format(col)),
    data:
      if isNull:
        nil
      else:
        cast[ptr UncheckedArray[byte]](pqgetvalue(row.res, 0, int32(col))),
    len:
      if isNull:
        0'i32
      else:
        pqgetlength(row.res, 0, int32(col)),
    isNull: isNull,
  )

proc `[]`*(row: PgInstantRow, col: int): string =
  let value = row.rawValue(col)
  if value.isNull:
    ""
  else:
    bytesToString(value.data, int(value.len))

proc get*[T](row: PgInstantRow, col: int, typ: typedesc[T]): T =
  pgDecode(T, row.rawValue(col))

proc columnIndex(row: PgInstantRow, name: string): int =
  int(pqfnumber(row.res, name.cstring))

proc decodeObject*[T: object](row: PgInstantRow, typ: typedesc[T]): T =
  for fieldName, fieldValue in fieldPairs(result):
    let col = row.columnIndex(fieldName)
    if col < 0:
      fail("PostgreSQL result is missing column " & fieldName)
    fieldValue = row.get(col, typeof(fieldValue))

iterator rowsParams[T: object](db: DbConn, query: SqlQuery, params: var PgParamSet): T =
  for row in instantBinaryRowsParams(db, query, params):
    yield row.decodeObject(T)

template rows*[T: object](
    db: DbConn, query: SqlQuery, args: varargs[untyped]
): untyped =
  block:
    var params = pgParams(args)
    rowsParams[T](db, query, params)

proc getAllParams[T: object](
    db: DbConn, query: SqlQuery, params: var PgParamSet
): seq[T] =
  for row in rowsParams[T](db, query, params):
    result.add(row)

template getAll*[T: object](
    db: DbConn, query: SqlQuery, args: varargs[untyped]
): untyped =
  block:
    var params = pgParams(args)
    getAllParams[T](db, query, params)
