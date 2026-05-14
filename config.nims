import std/[os, strutils]

--mm:atomicArc
--threads:on
--path:"deps/msgpack4nim/src"

proc requiredExe(bin: string): string =
  result = findExe(bin)
  if result.len == 0:
    quit("required executable not found in PATH: " & bin, 1)

proc pgExe(pgConfig, bin: string): string =
  result = findExe(bin)
  if result.len > 0:
    return

  let (bindirRaw, bindirStatus) = gorgeEx(pgConfig & " --bindir")
  if bindirStatus != 0:
    quit("failed to discover PostgreSQL bindir with pg_config --bindir", 1)

  result = bindirRaw.strip() / bin
  if not fileExists(result):
    quit("required PostgreSQL executable not found: " & bin, 1)

proc runTestFile(testFile: string) =
  exec("nim c -r " & quoteShell(testFile))

proc compileAndRunWithLibPath(testFile, libPath: string, extraEnv = "") =
  exec("nim c " & quoteShell(testFile))
  let bin = testFile.changeFileExt("")
  exec(
    "env " & extraEnv & " DYLD_LIBRARY_PATH=" & quoteShell(libPath) &
      " DYLD_FALLBACK_LIBRARY_PATH=" & quoteShell(libPath) & " LD_LIBRARY_PATH=" &
      quoteShell(libPath) & " " & quoteShell(bin)
  )

proc prependEnvPath(key, value: string) =
  let current = getEnv(key)
  if current.len == 0:
    putEnv(key, value)
  else:
    putEnv(key, value & PathSep & current)

task test, "run unit tests":
  for testFile in listFiles("tests/"):
    if testFile.endsWith(".nim") and testFile.splitFile().name.startsWith("t"):
      runTestFile(testFile)

task testPostgres, "start PostgreSQL and run unit plus integration tests":
  let
    pgConfig = requiredExe("pg_config")
    initdb = pgExe(pgConfig, "initdb")
    pgCtl = pgExe(pgConfig, "pg_ctl")
    dropdb = pgExe(pgConfig, "dropdb")
    createdb = pgExe(pgConfig, "createdb")
    pgData = getEnv("SQUEAL_PGDATA", "tests/postgrescache")
    pgPort = getEnv("SQUEAL_PG_PORT", "55432")
    pgHost = getEnv("SQUEAL_PG_HOST", "127.0.0.1")
    pgUser = getEnv("SQUEAL_PG_USER", getEnv("USER"))
    pgDatabase = getEnv("SQUEAL_PG_DATABASE", "squeal_test")
    pgLog = pgData / "postgres.log"

  if pgUser.len == 0:
    quit("SQUEAL_PG_USER or USER must be set", 1)

  let (pgLibDirRaw, pgLibDirStatus) = gorgeEx(pgConfig & " --libdir")
  if pgLibDirStatus != 0:
    quit("failed to discover PostgreSQL libdir with pg_config --libdir", 1)
  let pgLibDir = pgLibDirRaw.strip()
  prependEnvPath("DYLD_LIBRARY_PATH", pgLibDir)
  prependEnvPath("DYLD_FALLBACK_LIBRARY_PATH", pgLibDir)
  prependEnvPath("LD_LIBRARY_PATH", pgLibDir)

  if not fileExists(pgData / "PG_VERSION"):
    if not dirExists(pgData):
      mkDir(pgData)
    exec(initdb & " -A trust -U " & quoteShell(pgUser) & " -D " & quoteShell(pgData))

  let (_, statusCode) = gorgeEx(pgCtl & " -D " & quoteShell(pgData) & " status")
  let startedByTask = statusCode != 0

  if startedByTask:
    exec(
      pgCtl & " -D " & quoteShell(pgData) & " -o " &
        quoteShell("-h " & pgHost & " -p " & pgPort) & " -l " & quoteShell(pgLog) &
        " start -w"
    )

  try:
    let connArgs =
      " -h " & quoteShell(pgHost) & " -p " & quoteShell(pgPort) & " -U " &
      quoteShell(pgUser)

    discard gorgeEx(dropdb & connArgs & " --if-exists " & quoteShell(pgDatabase))
    exec(createdb & connArgs & " " & quoteShell(pgDatabase))

    putEnv("SQUEAL_PG_HOST", pgHost)
    putEnv("SQUEAL_PG_PORT", pgPort)
    putEnv("SQUEAL_PG_USER", pgUser)
    putEnv("SQUEAL_PG_PASSWORD", getEnv("SQUEAL_PG_PASSWORD", ""))
    putEnv("SQUEAL_PG_DATABASE", pgDatabase)

    for testFile in listFiles("tests/"):
      if testFile.endsWith(".nim") and testFile.splitFile().name.startsWith("t"):
        runTestFile(testFile)

    let benchEnv =
      "SQUEAL_BENCH_ROWS=" & quoteShell(getEnv("SQUEAL_BENCH_ROWS", "10000")) &
      " SQUEAL_BENCH_ITERS=" & quoteShell(getEnv("SQUEAL_BENCH_ITERS", "100"))

    compileAndRunWithLibPath("tests/integration/tpostgres_binary.nim", pgLibDir)
    compileAndRunWithLibPath(
      "tests/integration/bpostgres_binary.nim", pgLibDir, benchEnv
    )
  finally:
    if startedByTask:
      exec(pgCtl & " -D " & quoteShell(pgData) & " stop -m fast -w")

task benchmarkPostgres, "start PostgreSQL and run benchmark only":
  let
    pgConfig = requiredExe("pg_config")
    initdb = pgExe(pgConfig, "initdb")
    pgCtl = pgExe(pgConfig, "pg_ctl")
    dropdb = pgExe(pgConfig, "dropdb")
    createdb = pgExe(pgConfig, "createdb")
    pgData = getEnv("SQUEAL_PGDATA", "tests/postgrescache")
    pgPort = getEnv("SQUEAL_PG_PORT", "55432")
    pgHost = getEnv("SQUEAL_PG_HOST", "127.0.0.1")
    pgUser = getEnv("SQUEAL_PG_USER", getEnv("USER"))
    pgDatabase = getEnv("SQUEAL_PG_DATABASE", "squeal_bench")
    pgLog = pgData / "postgres.log"

  if pgUser.len == 0:
    quit("SQUEAL_PG_USER or USER must be set", 1)

  let (pgLibDirRaw, pgLibDirStatus) = gorgeEx(pgConfig & " --libdir")
  if pgLibDirStatus != 0:
    quit("failed to discover PostgreSQL libdir with pg_config --libdir", 1)
  let pgLibDir = pgLibDirRaw.strip()
  prependEnvPath("DYLD_LIBRARY_PATH", pgLibDir)
  prependEnvPath("DYLD_FALLBACK_LIBRARY_PATH", pgLibDir)
  prependEnvPath("LD_LIBRARY_PATH", pgLibDir)

  if not fileExists(pgData / "PG_VERSION"):
    if not dirExists(pgData):
      mkDir(pgData)
    exec(initdb & " -A trust -U " & quoteShell(pgUser) & " -D " & quoteShell(pgData))

  let (_, statusCode) = gorgeEx(pgCtl & " -D " & quoteShell(pgData) & " status")
  let startedByTask = statusCode != 0

  if startedByTask:
    exec(
      pgCtl & " -D " & quoteShell(pgData) & " -o " &
        quoteShell("-h " & pgHost & " -p " & pgPort) & " -l " & quoteShell(pgLog) &
        " start -w"
    )

  try:
    let connArgs =
      " -h " & quoteShell(pgHost) & " -p " & quoteShell(pgPort) & " -U " &
      quoteShell(pgUser)

    discard gorgeEx(dropdb & connArgs & " --if-exists " & quoteShell(pgDatabase))
    exec(createdb & connArgs & " " & quoteShell(pgDatabase))

    let benchEnv =
      "SQUEAL_PG_HOST=" & quoteShell(pgHost) & " SQUEAL_PG_PORT=" & quoteShell(pgPort) &
      " SQUEAL_PG_USER=" & quoteShell(pgUser) & " SQUEAL_PG_PASSWORD=" &
      quoteShell(getEnv("SQUEAL_PG_PASSWORD", "")) & " SQUEAL_PG_DATABASE=" &
      quoteShell(pgDatabase) & " SQUEAL_BENCH_ROWS=" &
      quoteShell(getEnv("SQUEAL_BENCH_ROWS", "10000")) & " SQUEAL_BENCH_ITERS=" &
      quoteShell(getEnv("SQUEAL_BENCH_ITERS", "100"))

    compileAndRunWithLibPath(
      "tests/integration/bpostgres_binary.nim", pgLibDir, benchEnv
    )
  finally:
    if startedByTask:
      exec(pgCtl & " -D " & quoteShell(pgData) & " stop -m fast -w")
