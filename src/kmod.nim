#
#          Copyright 2019 Leorize
#
# Licensed under the terms of the ISC license,
# see the file "license.txt" included within
# this distribution.

import macros, os, options, strutils
import kmod/raw

type
  KmodError* = object of Defect
  Context* = object
    ## Library user context, uses reference semantic
    impl: ptr kmodCtx
  Resources* = enum
    resOk,
    resMustReload,
    resMustRecreate
  Index* = enum
    idxModulesDep,
    idxModulesAlias,
    idxModulesSymbol,
    idxModulesBuiltin

proc `=destroy`*(c: var Context) {.inline.} =
  if not isNil c.impl:
    discard kmod_unref c.impl
    c.impl = nil

proc `=`*(a: var Context; b: Context) {.inline.} =
  let tmp = kmod_ref b.impl
  `=destroy` a
  a.impl = tmp

proc `=sink`*(a: var Context; b: Context) {.inline.} =
  if a.impl != b.impl:
    `=destroy` a
    a.impl = b.impl

proc newContext*(dirname = none string, confPaths = none seq[string]): Context =
  let
    cdirname = if isNone dirname:
                 cstring nil
               else:
                 cstring dirname.get
    cconfPaths = if isNone confPaths:
                   cstringArray nil
                 else:
                   allocCStringArray confPaths.get
  defer:
    if not isNil cconfPaths:
      deallocCStringArray cconfPaths
  result.impl = kmod_new(cdirname, cast[ptr cstring](cconfPaths))
  if isNil result.impl:
    raise newException(KmodError, "unable to create a context object")

proc logPriority*(c: Context): int {.inline.} =
  kmod_get_log_priority c.impl

proc `logPriority=`*(c: Context; priority: int) {.inline.} =
  kmod_set_log_priority c.impl, cint priority

proc dirname*(c: Context): Option[string] =
  let ret = kmod_get_dirname c.impl
  if not ret.isNil:
    some $ret
  else:
    none string

proc loadResources*(c: Context) {.inline.} =
  let ret = kmod_load_resources c.impl
  if ret < 0:
    raiseOSError OSErrorCode -ret

proc unloadResources*(c: Context) {.inline.} =
  kmod_unload_resources c.impl

proc validateResources*(c: Context): Resources {.inline.} =
  Resources kmod_validate_resources c.impl

proc dumpIndex*(c: Context, `type`: Index; fd: FileHandle) {.inline.} =
  let ret = kmod_dump_index(c.impl, kmod_index `type`, fd)
  if ret < 0:
    raiseOSError OSErrorCode -ret

type
  ConfigIter* = object
    impl: ptr kmod_config_iter

proc `=destroy`*(ci: var ConfigIter) {.inline.} =
  if not isNil ci.impl:
    kmod_config_iter_free_iter ci.impl
    ci.impl = nil

proc `=`*(a: var ConfigIter; b: ConfigIter) {.error.}

proc `=sink`*(a: var ConfigIter; b: ConfigIter) {.inline.} =
  if a.impl != b.impl:
    `=destroy` a
    a.impl = b.impl

proc key*(ci: ConfigIter): string {.inline.} =
  $kmod_config_iter_get_key(ci.impl)

proc value*(ci: ConfigIter): string {.inline.} =
  $kmod_config_iter_get_value(ci.impl)

proc next*(ci: ConfigIter): bool {.inline.} =
  kmod_config_iter_next ci.impl

iterator pairs*(ci: ConfigIter): tuple[key, value: string] {.inline.} =
  yield (ci.key, ci.value)
  while ci.next:
    yield (ci.key, ci.value)
  discard ci.next # reset iterator

macro cfgIterGetGen(what: untyped): untyped =
  proc camelCase(s: string): string =
    var upper = false
    for i in s:
      if i == '_':
        upper = true
      elif upper:
        result.add toUpperAscii i
        upper = false
      else:
        result.add i

  expectKind what, nnkIdent
  let
    impl = ident "kmod_config_get_" & what.strVal
    pname = ident camelCase what.strVal
    errMsg = "unable to get " & replace(what.strVal, '_', ' ')

  result = quote do:
    proc `pname`*(c: Context): ConfigIter {.inline.} =
      result.impl = `impl` c.impl
      if not kmod_config_iter_next result.impl:
        raise newException(KmodError, `errMsg`)

cfgIterGetGen blacklists
cfgIterGetGen install_commands
cfgIterGetGen remove_commands
cfgIterGetGen aliases
cfgIterGetGen options
cfgIterGetGen softdeps

template genListImpl(list: untyped; destructor: untyped): untyped =
  type
    `list`* {.inject.} = object
      impl: ptr kmod_list
      refcnt: ptr int

  proc `=destroy`*(l: var `list`) {.inline.} =
    template lst: untyped {.inject.} = l
    if not isNil l.refcnt:
      if atomicDec(l.refcnt[], 1) <= 0:
        assert atomicDec(l.refcnt[], 0) == 0
        destructor
        dealloc l.refcnt
      l.impl = nil
      l.refcnt = nil

  proc `=`*(a: var `list`; b: `list`) {.inline.} =
    if not isNil b.refcnt:
      atomicInc b.refcnt[]
      `=destroy` a
      a.impl = b.impl
      a.refcnt = b.refcnt

  proc `=sink`*(a: var `list`; b: `list`) {.inline.} =
    if a.impl != b.impl:
      `=destroy` a
      a.impl = b.impl
      a.refcnt = b.refcnt

  proc makeOptionList(head: `list`, lst: ptr kmod_list): Option[`list`] {.gensym.} =
    if not isNil lst:
      atomicInc head.refcnt[]
      var res = `list`(impl: lst, refcnt: head.refcnt)
      some move res
    else:
      none `list`

  proc next*(head, curr: `list`): Option[`list`] =
    if head.refcnt != curr.refcnt:
      raise newException(KmodError, "curr must be a part of the head list")
    makeOptionList head, kmod_list_next(head.impl, curr.impl)

  proc prev*(head, curr: `list`): Option[`list`] =
    if head.refcnt != curr.refcnt:
      raise newException(KmodError, "curr must be a part of the head list")
    makeOptionList head, kmod_list_prev(head.impl, curr.impl)

  proc last*(lst: `list`): Option[`list`] =
    makeOptionList lst, kmod_list_last lst.impl

  iterator entries*(lst: `list`): `list` =
    var curr = lst.impl
    while not isNil curr:
      discard atomicInc lst.refcnt[]
      yield `list`(impl: curr, refcnt: lst.refcnt)
      curr = kmod_list_next(lst.impl, curr)

type
  Module* = object
    impl: ptr kmod_module
  Remove* = enum
    remForce,
    remNoWait
  Insert* = enum
    insForceVerMagic,
    insForceModVersion
  Filter* = enum
    fltBlacklist,
    fltBuiltin
  InitState* = enum
    istBuiltin,
    istLive,
    istComing,
    istGoing

proc `=destroy`*(m: var Module) {.inline.} =
  discard kmod_module_unref m.impl
  m.impl = nil

proc `=`*(a: var Module; b: Module) {.inline.} =
  let tmp = kmod_module_ref b.impl
  `=destroy` a
  a.impl = tmp

proc `=sink`*(a: var Module; b: Module) {.inline.} =
  if a.impl != b.impl:
    `=destroy` a
    a.impl = b.impl

proc newModuleFromName*(c: Context; name: string): Module {.inline.} =
  let ret = kmod_module_new_from_name(c.impl, name, addr result.impl)
  if ret < 0:
    raiseOSError OSErrorCode -ret

proc newModuleFromPath*(c: Context; path: string): Module {.inline.} =
  let ret = kmod_module_new_from_path(c.impl, path, addr result.impl)
  if ret < 0:
    raiseOSError OSErrorCode -ret

genListImpl ModuleList:
  discard kmod_module_unref_list lst.impl

proc newModuleListFromLookup*(c: Context; alias: string): ModuleList =
  let ret = kmod_module_new_from_lookup(c.impl, alias, addr result.impl)
  if ret < 0:
    raiseOSError OSErrorCode -ret
  result.refcnt = create int
  result.refcnt[] = 1

proc newModuleListFromLoaded*(c: Context): ModuleList =
  let ret = kmod_module_new_from_loaded(c.impl, addr result.impl)
  if ret < 0:
    raiseOSError OSErrorCode -ret
  result.refcnt = create int
  result.refcnt[] = 1

proc module*(entry: ModuleList): Module =
  result.impl = kmod_module_get_module entry.impl
  if isNil result.impl:
    raise newException(KmodError, "unable to get module")

iterator items*(entry: ModuleList): Module =
  for i in entries entry:
    yield i.module

proc remove*(m: Module; flags: set[Remove]) =
  var fls: kmod_remove
  for i in flags:
    fls = fls or (case i
                  of remForce: KMOD_REMOVE_FORCE
                  of remNoWait: KMOD_REMOVE_NOWAIT)
  let ret = kmod_module_remove_module(m.impl, cuint fls)
  if ret < 0:
    raiseOSError OSErrorCode -ret

proc insert*(m: Module; flags: set[Insert]; options: string) =
  var fls: kmod_insert
  for i in flags:
    fls = fls or (case i
                  of insForceVerMagic: KMOD_INSERT_FORCE_VERMAGIC
                  of insForceModVersion: KMOD_INSERT_FORCE_MODVERSION)
  let ret = kmod_module_insert_module(m.impl, cuint fls, options)
  if ret < 0:
    raiseOSError OSErrorCode -ret

proc name*(m: Module): string {.inline.} =
  $kmod_module_get_name m.impl

proc path*(m: Module): string {.inline.} =
  $kmod_module_get_path m.impl

proc options*(m: Module): string {.inline.} =
  $kmod_module_get_options m.impl

proc installCommands*(m: Module): string {.inline.} =
  $kmod_module_get_install_commands m.impl

proc removeCommands*(m: Module): string {.inline.} =
  $kmod_module_get_remove_commands m.impl

proc dependencies*(m: Module): ModuleList {.inline.} =
  result.impl = kmod_module_get_dependencies m.impl
  if isNil result.impl:
    raise newException(KmodError, "unable to get dependencies")
  result.refcnt = create int
  result.refcnt[] = 1

proc softdeps*(m: Module): tuple[pre, post: ModuleList] {.inline.} =
  let ret = kmod_module_get_softdeps(m.impl, addr result.pre.impl, addr result.post.impl)
  if ret < 0:
    raiseOSError OSErrorCode -ret
  result.pre.refcnt = create int
  result.pre.refcnt[] = 1
  result.post.refcnt = create int
  result.post.refcnt[] = 1

proc applyFilter*(ml: ModuleList; c: Context; filters: set[Filter]): ModuleList =
  var fls: kmod_filter
  for i in filters:
    fls = fls or (case i
                  of fltBuiltin: KMOD_FILTER_BUILTIN
                  of fltBlacklist: KMOD_FILTER_BLACKLIST)
  let ret = kmod_module_apply_filter(c.impl, fls, ml.impl, addr result.impl)
  if ret < 0:
    raiseOSError OSErrorCode -ret
  result.refcnt = create int
  result.refcnt[] = 1

proc `$`*(s: InitState): string {.inline.} =
  $kmod_module_initstate_str(kmod_module_initstate s)

proc initstate*(m: Module): InitState {.inline.} =
  let ret = kmod_module_get_initstate m.impl
  if ret < 0:
    raiseOSError OSErrorCode -ret
  result = InitState ret

proc refcnt*(m: Module): int {.inline.} =
  result = kmod_module_get_refcnt m.impl
  if result < 0:
    raiseOSError OSErrorCode -result

proc holders*(m: Module): Option[ModuleList] {.inline.} =
  var res: ModuleList
  res.impl = kmod_module_get_holders m.impl
  if isNil res.impl:
    return
  res.refcnt = create int
  res.refcnt[] = 1
  result = some move res

genListImpl ModuleSectionList:
  kmod_module_section_free_list lst.impl

proc sections*(m: Module): ModuleSectionList {.inline.} =
  result.impl = kmod_module_get_sections m.impl
  if isNil result.impl:
    raise newException(KmodError, "unable to get holders")
  result.refcnt = create int
  result.refcnt[] = 1

proc name*(msl: ModuleSectionList): string =
  let ret = kmod_module_section_get_name msl.impl
  if isNil ret:
    raise newException(KmodError, "unable to get name")
  $ret

proc address*(msl: ModuleSectionList): uint =
  result = kmod_module_section_get_address msl.impl
  var ulong_max {.importc: "ULONG_MAX", header: "<limits.h>".}: uint
  if result == ulong_max:
    raise newException(KmodError, "unable to get address")

proc size*(m: Module): int =
  result = kmod_module_get_size m.impl
  if result < 0:
    raiseOSError OSErrorCode -result

iterator pairs*(msl: ModuleSectionList): tuple[address: uint, name: string] =
  for i in entries msl:
    yield (i.address, i.name)

genListImpl ModuleInfoList:
  kmod_module_info_free_list lst.impl

proc info*(m: Module): ModuleInfoList {.inline.} =
  let ret = kmod_module_get_info(m.impl, addr result.impl)
  if ret < 0:
    raiseOSError OSErrorCode -ret

proc key*(mil: ModuleInfoList): string {.inline.} =
  let ret = kmod_module_info_get_key mil.impl
  if isNil ret:
    raise newException(KmodError, "unable to get key")
  $ret

proc value*(mil: ModuleInfoList): string {.inline.} =
  let ret = kmod_module_info_get_value mil.impl
  if isNil ret:
    raise newException(KmodError, "unable to get value")
  $ret

iterator pairs*(mil: ModuleInfoList): tuple[key, value: string] =
  for i in entries mil:
    yield (i.key, i.value)

genListImpl ModuleVersionList:
  kmod_module_versions_free_list lst.impl

proc versions*(m: Module): ModuleVersionList {.inline.} =
  let ret = kmod_module_get_versions(m.impl, addr result.impl)
  if ret < 0:
    raiseOSError OSErrorCode -ret
  result.refcnt = create int
  result.refcnt[] = 1

proc symbol*(mil: ModuleVersionList): string {.inline.} =
  let ret = kmod_module_version_get_symbol mil.impl
  if isNil ret:
    raise newException(KmodError, "unable to get symbol")
  $ret

proc crc*(mil: ModuleVersionList): uint64 {.inline.} =
  result = kmod_module_version_get_crc mil.impl

iterator pairs*(mil: ModuleVersionList): tuple[symbol: string, crc: uint64] =
  for i in entries mil:
    yield (i.symbol, i.crc)

genListImpl ModuleSymbolList:
  kmod_module_symbols_free_list lst.impl

proc symbols*(m: Module): ModuleSymbolList {.inline.} =
  let ret = kmod_module_get_symbols(m.impl, addr result.impl)
  if ret < 0:
    raiseOSError OSErrorCode -ret
  result.refcnt = create int
  result.refcnt[] = 1

proc symbol*(mil: ModuleSymbolList): string {.inline.} =
  let ret = kmod_module_symbol_get_symbol mil.impl
  if isNil ret:
    raise newException(KmodError, "unable to get symbol")
  $ret

proc crc*(mil: ModuleSymbolList): uint64 {.inline.} =
  kmod_module_symbol_get_crc mil.impl

iterator pairs*(mil: ModuleSymbolList): tuple[symbol: string, crc: uint64] =
  for i in entries mil:
    yield (i.symbol, i.crc)

genListImpl ModuleDependencySymbolList:
  kmod_module_dependency_symbols_free_list lst.impl

type
  SymbolBind = enum
    sbNone = "",
    sbLocal = "L",
    sbGlobal = "G",
    sbWeak = "W",
    sbUndef = "U"

proc dependencySymbols*(m: Module): ModuleDependencySymbolList =
  let ret = kmod_module_get_dependency_symbols(m.impl, addr result.impl)
  if ret < 0:
    raiseOSError OSErrorCode -ret
  result.refcnt = create int
  result.refcnt[] = 1

proc symbol*(mdsl: ModuleDependencySymbolList): string =
  let ret = kmod_module_dependency_symbol_get_symbol mdsl.impl
  if isNil ret:
    raise newException(KmodError, "unable to get symbol")
  $ret

proc `bind`*(mdsl: ModuleDependencySymbolList): SymbolBind =
  let ret = kmod_module_dependency_symbol_get_bind mdsl.impl
  if ret < 0:
    raise newException(KmodError, "unable to get bind")
  case kmodSymbolBind ret
  of KMOD_SYMBOL_NONE: sbNone
  of KMOD_SYMBOL_LOCAL: sbLocal
  of KMOD_SYMBOL_GLOBAL: sbGlobal
  of KMOD_SYMBOL_WEAK: sbWeak
  of KMOD_SYMBOL_UNDEF: sbUndef
  else: raise newException(KmodError, "unknown bind")

proc crc*(mdsl: ModuleDependencySymbolList): uint64 =
  kmod_module_dependency_symbol_get_crc mdsl.impl
