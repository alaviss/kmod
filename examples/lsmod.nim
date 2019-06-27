#
#          Copyright 2019 Leorize
#
# Licensed under the terms of the ISC license,
# see the file "license.txt" included within
# this distribution.

import options, strformat
import kmod

proc main() =
  echo &"""{"Module":<19} {"Size":>8}  Used by"""
  for m in newContext().newModuleListFromLoaded:
    stdout.write &"{m.name:<19} {m.size:>8}  {m.refcnt}"
    let holders = m.holders
    if holders.isSome:
      var first = true
      for h in holders.unsafeGet:
        if first: stdout.write ' '
        if not first: stdout.write ','
        stdout.write h.name
        first = false
    stdout.write '\n'

when isMainModule: main()
