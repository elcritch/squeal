version       = "0.1.0"
author        = "Your Name"
description   = "A Nim package."
license       = "Apache-2.0"
srcDir        = "src"

requires "nim >= 2.0.0"

requires "https://github.com/nim-lang/db_connector"

feature "dev":
  requires "ormin"

