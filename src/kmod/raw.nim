#
#          Copyright 2019 Leorize
#
# Licensed under the terms of the ISC license,
# see the file "license.txt" included within
# this distribution.

import nimterop/cimport

const ldflags = staticExec "pkg-config --libs libkmod"
{.passL: ldflags.}
static:
  caddStdDir()
  cskipSymbol @["_KMOD_INDEX_PAD", "_KMOD_MODULE_PAD"]
cimport csearchPath "libkmod.h"
