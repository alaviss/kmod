import unittest

import kmod

# The compiler blew up on this once
test "iterate through loaded modules":
  let ctx = newContext()
  for i in ctx.newModuleListFromLoaded:
    discard i.name
