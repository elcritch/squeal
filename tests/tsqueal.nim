import std/unittest

import squeal

suite "squeal":
  test "greets by name":
    check greet("Nim") == "hello, Nim"

