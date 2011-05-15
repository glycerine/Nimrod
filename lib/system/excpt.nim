#
#
#            Nimrod's Runtime Library
#        (c) Copyright 2011 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

# Exception handling code. This is difficult because it has
# to work if there is no more memory (but it doesn't yet!).

var
  stackTraceNewLine* = "\n" ## undocumented feature; it is replaced by ``<br>``
                            ## for CGI applications
  isMultiThreaded: bool # true when prog created at least 1 thread

when not defined(windows) or not defined(guiapp):
  proc writeToStdErr(msg: CString) = write(stdout, msg)

else:
  proc MessageBoxA(hWnd: cint, lpText, lpCaption: cstring, uType: int): int32 {.
    header: "<windows.h>", nodecl.}

  proc writeToStdErr(msg: CString) =
    discard MessageBoxA(0, msg, nil, 0)

proc registerSignalHandler() {.compilerproc.}

proc chckIndx(i, a, b: int): int {.inline, compilerproc.}
proc chckRange(i, a, b: int): int {.inline, compilerproc.}
proc chckRangeF(x, a, b: float): float {.inline, compilerproc.}
proc chckNil(p: pointer) {.inline, compilerproc.}

type
  PSafePoint = ptr TSafePoint
  TSafePoint {.compilerproc, final.} = object
    prev: PSafePoint # points to next safe point ON THE STACK
    status: int
    context: C_JmpBuf

when hasThreadSupport:
  # Support for thread local storage:
  when defined(windows):
    type
      TThreadVarSlot {.compilerproc.} = distinct int32

    proc TlsAlloc(): TThreadVarSlot {.
      importc: "TlsAlloc", stdcall, dynlib: "kernel32".}
    proc TlsSetValue(dwTlsIndex: TThreadVarSlot, lpTlsValue: pointer) {.
      importc: "TlsSetValue", stdcall, dynlib: "kernel32".}
    proc TlsGetValue(dwTlsIndex: TThreadVarSlot): pointer {.
      importc: "TlsGetValue", stdcall, dynlib: "kernel32".}
    
    proc ThreadVarAlloc(): TThreadVarSlot {.compilerproc, inline.} =
      result = TlsAlloc()
    proc ThreadVarSetValue(s: TThreadVarSlot, value: pointer) {.
                           compilerproc, inline.} =
      TlsSetValue(s, value)
    proc ThreadVarGetValue(s: TThreadVarSlot): pointer {.
                           compilerproc, inline.} =
      result = TlsGetValue(s)
    
  else:
    {.passL: "-pthread".}
    {.passC: "-pthread".}

    type
      Tpthread_key {.importc: "pthread_key_t", 
                     header: "<sys/types.h>".} = distinct int
      TThreadVarSlot {.compilerproc.} = Tpthread_key

    proc pthread_getspecific(a1: Tpthread_key): pointer {.
      importc: "pthread_getspecific", header: "<pthread.h>".}
    proc pthread_key_create(a1: ptr Tpthread_key, 
                            destruct: proc (x: pointer) {.noconv.}): int32 {.
      importc: "pthread_key_create", header: "<pthread.h>".}
    proc pthread_key_delete(a1: Tpthread_key): int32 {.
      importc: "pthread_key_delete", header: "<pthread.h>".}

    proc pthread_setspecific(a1: Tpthread_key, a2: pointer): int32 {.
      importc: "pthread_setspecific", header: "<pthread.h>".}
    
    proc specificDestroy(mem: pointer) {.noconv.} = dealloc(mem)
    
    proc ThreadVarAlloc(): TThreadVarSlot {.compilerproc, inline.} =
      discard pthread_key_create(addr(result), specificDestroy)
    proc ThreadVarSetValue(s: TThreadVarSlot, value: pointer) {.
                           compilerproc, inline.} =
      discard pthread_setspecific(s, value)
    proc ThreadVarGetValue(s: TThreadVarSlot): pointer {.compilerproc, inline.} =
      result = pthread_getspecific(s)
      
  type
    TGlobals {.final, pure.} = object
      excHandler: PSafePoint
      currException: ref E_Base
      framePtr: PFrame
      buf: string       # cannot be allocated on the stack!
      assertBuf: string # we need a different buffer for
                        # assert, as it raises an exception and
                        # exception handler needs the buffer too
      gAssertionFailed: ref EAssertionFailed
      tempFrames: array [0..127, PFrame] # cannot be allocated on the stack!
      data: float # compiler should add thread local variables here!
    PGlobals = ptr TGlobals

  var globalsSlot = ThreadVarAlloc()
  proc CreateThreadLocalStorage*(): pointer {.inl.} =
    isMultiThreaded = true
    result = alloc0(sizeof(TGlobals))
    ThreadVarSetValue(globalsSlot, result)
    
  proc GetGlobals(): PGlobals {.compilerRtl, inl.} =
    result = cast[PGlobals](ThreadVarGetValue(globalsSlot))

  # create for the main thread:
  ThreadVarSetValue(globalsSlot, alloc0(sizeof(TGlobals)))

when hasThreadSupport:
  template ThreadGlobals = 
    var globals = GetGlobals()
  template `||`(varname: expr): expr = globals.varname
  
  ThreadGlobals()
else:
  template ThreadGlobals = nil # nothing
  template `||`(varname: expr): expr = varname

  var
    framePtr {.compilerproc.}: PFrame # XXX only temporarily a compilerproc
    excHandler: PSafePoint = nil
      # list of exception handlers
      # a global variable for the root of all try blocks
    currException: ref E_Base

    buf: string       # cannot be allocated on the stack!
    assertBuf: string # we need a different buffer for
                      # assert, as it raises an exception and
                      # exception handler needs the buffer too
    tempFrames: array [0..127, PFrame] # cannot be allocated on the stack!
    gAssertionFailed: ref EAssertionFailed

proc pushFrame(s: PFrame) {.compilerRtl, inl.} = 
  ThreadGlobals()
  s.prev = ||framePtr
  ||framePtr = s

proc popFrame {.compilerRtl, inl.} =
  ThreadGlobals()
  ||framePtr = (||framePtr).prev

proc setFrame(s: PFrame) {.compilerRtl, inl.} =
  ThreadGlobals()
  ||framePtr = s

proc pushSafePoint(s: PSafePoint) {.compilerRtl, inl.} = 
  ThreadGlobals()
  s.prev = ||excHandler
  ||excHandler = s

proc popSafePoint {.compilerRtl, inl.} =
  ThreadGlobals()
  ||excHandler = (||excHandler).prev

proc pushCurrentException(e: ref E_Base) {.compilerRtl, inl.} = 
  ThreadGlobals()
  e.parent = ||currException
  ||currException = e

proc popCurrentException {.compilerRtl, inl.} =
  ThreadGlobals()
  ||currException = (||currException).parent

# some platforms have native support for stack traces:
const
   nativeStackTraceSupported = (defined(macosx) or defined(linux)) and 
                               not nimrodStackTrace

when defined(nativeStacktrace) and nativeStackTraceSupported:
  type
    TDl_info {.importc: "Dl_info", header: "<dlfcn.h>", 
               final, pure.} = object
      dli_fname: CString
      dli_fbase: pointer
      dli_sname: CString
      dli_saddr: pointer

  proc backtrace(symbols: ptr pointer, size: int): int {.
    importc: "backtrace", header: "<execinfo.h>".}
  proc dladdr(addr1: pointer, info: ptr TDl_info): int {.
    importc: "dladdr", header: "<dlfcn.h>".}

  when not hasThreadSupport:
    var
      tempAddresses: array [0..127, pointer] # should not be alloc'd on stack
      tempDlInfo: TDl_info

  proc auxWriteStackTraceWithBacktrace(s: var string) =
    when hasThreadSupport:
      var
        tempAddresses: array [0..127, pointer] # but better than a threadvar
        tempDlInfo: TDl_info
    # This is allowed to be expensive since it only happens during crashes
    # (but this way you don't need manual stack tracing)
    var size = backtrace(cast[ptr pointer](addr(tempAddresses)), 
                         len(tempAddresses))
    var enabled = false
    for i in 0..size-1:
      var dlresult = dladdr(tempAddresses[i], addr(tempDlInfo))
      if enabled:
        if dlresult != 0:
          var oldLen = s.len
          add(s, tempDlInfo.dli_fname)
          if tempDlInfo.dli_sname != nil:
            for k in 1..max(1, 25-(s.len-oldLen)): add(s, ' ')
            add(s, tempDlInfo.dli_sname)
        else:
          add(s, '?')
        add(s, stackTraceNewLine)
      else:
        if dlresult != 0 and tempDlInfo.dli_sname != nil and
            c_strcmp(tempDlInfo.dli_sname, "signalHandler") == 0'i32:
          # Once we're past signalHandler, we're at what the user is
          # interested in
          enabled = true
  
proc auxWriteStackTrace(f: PFrame, s: var string) =
  const 
    firstCalls = 32
  ThreadGlobals()  
  var
    it = f
    i = 0
    total = 0
  while it != nil and i <= high(||tempFrames)-(firstCalls-1):
    # the (-1) is for a nil entry that marks where the '...' should occur
    (||tempFrames)[i] = it
    inc(i)
    inc(total)
    it = it.prev
  var b = it
  while it != nil:
    inc(total)
    it = it.prev
  for j in 1..total-i-(firstCalls-1): 
    if b != nil: b = b.prev
  if total != i:
    (||tempFrames)[i] = nil
    inc(i)
  while b != nil and i <= high(||tempFrames):
    (||tempFrames)[i] = b
    inc(i)
    b = b.prev
  for j in countdown(i-1, 0):
    if (||tempFrames)[j] == nil: 
      add(s, "(")
      add(s, $(total-i-1))
      add(s, " calls omitted) ...")
    else:
      var oldLen = s.len
      add(s, (||tempFrames)[j].filename)
      if (||tempFrames)[j].line > 0:
        add(s, '(')
        add(s, $(||tempFrames)[j].line)
        add(s, ')')
      for k in 1..max(1, 25-(s.len-oldLen)): add(s, ' ')
      add(s, (||tempFrames)[j].procname)
    add(s, stackTraceNewLine)

proc rawWriteStackTrace(s: var string) =
  when nimrodStackTrace:
    ThreadGlobals()
    if ||framePtr == nil:
      add(s, "No stack traceback available")
      add(s, stackTraceNewLine)
    else:
      add(s, "Traceback (most recent call last)")
      add(s, stackTraceNewLine)
      auxWriteStackTrace(||framePtr, s)
  elif defined(nativeStackTrace) and nativeStackTraceSupported:
    add(s, "Traceback from system (most recent call last)")
    add(s, stackTraceNewLine)
    auxWriteStackTraceWithBacktrace(s)
  else:
    add(s, "No stack traceback available")
    add(s, stackTraceNewLine)

proc quitOrDebug() {.inline.} =
  when not defined(endb):
    quit(1)
  else:
    endbStep() # call the debugger

proc raiseException(e: ref E_Base, ename: CString) {.compilerRtl.} =
  GC_disable() # a bad thing is an error in the GC while raising an exception
  e.name = ename
  ThreadGlobals()
  if ||excHandler != nil:
    pushCurrentException(e)
    c_longjmp((||excHandler).context, 1)
  else:
    if not isNil(||buf):
      setLen(||buf, 0)
      rawWriteStackTrace(||buf)
      if e.msg != nil and e.msg[0] != '\0':
        add(||buf, "Error: unhandled exception: ")
        add(||buf, $e.msg)
      else:
        add(||buf, "Error: unhandled exception")
      add(||buf, " [")
      add(||buf, $ename)
      add(||buf, "]\n")
      writeToStdErr(||buf)
    else:
      writeToStdErr(ename)
    quitOrDebug()
  GC_enable()

proc reraiseException() {.compilerRtl.} =
  ThreadGlobals()
  if ||currException == nil:
    raise newException(ENoExceptionToReraise, "no exception to reraise")
  else:
    raiseException(||currException, (||currException).name)

proc internalAssert(file: cstring, line: int, cond: bool) {.compilerproc.} =
  if not cond:
    ThreadGlobals()    
    #c_fprintf(c_stdout, "Assertion failure: file %s line %ld\n", file, line)
    #quit(1)
    GC_disable() # BUGFIX: `$` allocates a new string object!
    if not isNil(||assertBuf):
      # BUGFIX: when debugging the GC, assertBuf may be nil
      setLen(||assertBuf, 0)
      add(||assertBuf, "[Assertion failure] file: ")
      add(||assertBuf, file)
      add(||assertBuf, " line: ")
      add(||assertBuf, $line)
      add(||assertBuf, "\n")
      (||gAssertionFailed).msg = ||assertBuf
    GC_enable()
    if ||gAssertionFailed != nil:
      raise ||gAssertionFailed
    else:
      c_fprintf(c_stdout, "Assertion failure: file %s line %ld\n", file, line)
      quit(1)

proc WriteStackTrace() =
  var s = ""
  rawWriteStackTrace(s)
  writeToStdErr(s)

var
  dbgAborting: bool # whether the debugger wants to abort

proc signalHandler(sig: cint) {.exportc: "signalHandler", noconv.} =
  # print stack trace and quit
  ThreadGlobals()
  var s = sig
  GC_disable()
  setLen(||buf, 0)
  rawWriteStackTrace(||buf)

  if s == SIGINT: add(||buf, "SIGINT: Interrupted by Ctrl-C.\n")
  elif s == SIGSEGV: 
    add(||buf, "SIGSEGV: Illegal storage access. (Attempt to read from nil?)\n")
  elif s == SIGABRT:
    if dbgAborting: return # the debugger wants to abort
    add(||buf, "SIGABRT: Abnormal termination.\n")
  elif s == SIGFPE: add(||buf, "SIGFPE: Arithmetic error.\n")
  elif s == SIGILL: add(||buf, "SIGILL: Illegal operation.\n")
  elif s == SIGBUS: 
    add(||buf, "SIGBUS: Illegal storage access. (Attempt to read from nil?)\n")
  else: add(||buf, "unknown signal\n")
  writeToStdErr(||buf)
  dbgAborting = True # play safe here...
  GC_enable()
  quit(1) # always quit when SIGABRT

proc registerSignalHandler() =
  c_signal(SIGINT, signalHandler)
  c_signal(SIGSEGV, signalHandler)
  c_signal(SIGABRT, signalHandler)
  c_signal(SIGFPE, signalHandler)
  c_signal(SIGILL, signalHandler)
  c_signal(SIGBUS, signalHandler)

when not defined(noSignalHandler):
  registerSignalHandler() # call it in initialization section
# for easier debugging of the GC, this memory is only allocated after the
# signal handlers have been registered
new(||gAssertionFailed)
||buf = newStringOfCap(2000)
||assertBuf = newStringOfCap(2000)

proc raiseRangeError(val: biggestInt) {.compilerproc, noreturn, noinline.} =
  raise newException(EOutOfRange, "value " & $val & " out of range")

proc raiseIndexError() {.compilerproc, noreturn, noinline.} =
  raise newException(EInvalidIndex, "index out of bounds")

proc raiseFieldError(f: string) {.compilerproc, noreturn, noinline.} =
  raise newException(EInvalidField, f & " is not accessible")

proc chckIndx(i, a, b: int): int =
  if i >= a and i <= b:
    return i
  else:
    raiseIndexError()

proc chckRange(i, a, b: int): int =
  if i >= a and i <= b:
    return i
  else:
    raiseRangeError(i)

proc chckRange64(i, a, b: int64): int64 {.compilerproc.} =
  if i >= a and i <= b:
    return i
  else:
    raiseRangeError(i)

proc chckRangeF(x, a, b: float): float =
  if x >= a and x <= b:
    return x
  else:
    raise newException(EOutOfRange, "value " & $x & " out of range")

proc chckNil(p: pointer) =
  if p == nil: c_raise(SIGSEGV)

proc chckObj(obj, subclass: PNimType) {.compilerproc.} =
  # checks if obj is of type subclass:
  var x = obj
  if x == subclass: return # optimized fast path
  while x != subclass:
    if x == nil:
      raise newException(EInvalidObjectConversion, "invalid object conversion")
    x = x.base

proc chckObjAsgn(a, b: PNimType) {.compilerproc, inline.} =
  if a != b:
    raise newException(EInvalidObjectAssignment, "invalid object assignment")

proc isObj(obj, subclass: PNimType): bool {.compilerproc.} =
  # checks if obj is of type subclass:
  var x = obj
  if x == subclass: return true # optimized fast path
  while x != subclass:
    if x == nil: return false
    x = x.base
  return true
