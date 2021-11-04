import
  macros, tables, strutils, strformat,
  chronicles/[scope_helpers, dynamic_scope, log_output, options]

export
  dynamic_scope, log_output, options

# So, how does Chronicles work?
#
# The tricky part is understanding how the lexical scopes are implemened.
# For them to work, we need to be able to associate a mutable compile-time
# data with a lexical scope (with a different value for each scope).
# The regular compile-time variable are not suited for this, because they
# offer us only a single global value that can be mutated.
#
# Luckily, we can use the body of a template as the storage mechanism for
# our data. This works, because template names bound to particular scopes
# and templates can be freely redefined as many times as necessary.
#
# `activeChroniclesScope` stores the current lexical scope.
#
# `logScopeIMPL` is used to merge a previously defined scope with some
# new definition in order to produce a new scope:
#

template activeChroniclesScope* =
  0 # track the scope revision

macro logScopeIMPL(prevScopes: typed,
                   newBindings: untyped,
                   isPublic: static[bool]): untyped =
  result = newStmtList()
  var
    bestScope = prevScopes.lastScopeBody
    bestScopeRev = bestScope.scopeRevision
    newRevision = newLit(bestScopeRev + 1)
    finalBindings = initTable[string, NimNode]()
    newAssingments = newStmtList()
    chroniclesExportNode: NimNode = if not isPublic: nil
                                    else: newTree(nnkExportExceptStmt,
                                                  id"chronicles",
                                                  id"activeChroniclesScope")

  for k, v in assignments(bestScope.scopeAssignments, acScopeBlock):
    finalBindings[k] = v

  for k, v in assignments(newBindings, acScopeBlock):
    finalBindings[k] = v

  for k, v in finalBindings:
    if k == "stream":
      let streamId = id($v)
      let errorMsg = &"{v.lineInfo}: {$streamId} is not a recognized stream name"
      let templateName = id("activeChroniclesStream", isPublic)

      result.add quote do:
        when not declared(`streamId`):
          # XXX: how to report the proper line info here?
          {.error: `errorMsg`.}
        #elif not isStreamSymbolIMPL(`streamId`):
        #  {.error: `errorMsg`.}
        template `templateName`: type = `streamId`

      if isPublic:
        chroniclesExportNode.add id"activeChroniclesStream"

    else:
      newAssingments.add newAssignment(id(k), v)

  if isPublic:
    result.add chroniclesExportNode

  let activeScope = id("activeChroniclesScope", isPublic)
  result.add quote do:
    template `activeScope` =
      `newRevision`
      `newAssingments`

template logScope*(newBindings: untyped) {.dirty.} =
  bind bindSym, logScopeIMPL, brForceOpen
  logScopeIMPL(bindSym("activeChroniclesScope", brForceOpen),
               newBindings, false)

template publicLogScope*(newBindings: untyped) {.dirty.} =
  bind bindSym, logScopeIMPL, brForceOpen
  logScopeIMPL(bindSym("activeChroniclesScope", brForceOpen),
               newBindings, true)

template dynamicLogScope*(stream: type,
                          bindings: varargs[untyped]) {.dirty.} =
  bind bindSym, brForceOpen
  dynamicLogScopeIMPL(stream,
                      bindSym("activeChroniclesScope", brForceOpen),
                      bindings)

template dynamicLogScope*(bindings: varargs[untyped]) {.dirty.} =
  bind bindSym, brForceOpen
  dynamicLogScopeIMPL(activeChroniclesStream(),
                      bindSym("activeChroniclesScope", brForceOpen),
                      bindings)

let chroniclesBlockName {.compileTime.} = ident "chroniclesLogStmt"
let chroniclesTopicsMatchVar {.compileTime.} = ident "chroniclesTopicsMatch"

when runtimeFilteringEnabled:
  import chronicles/topics_registry
  export setTopicState, setLogLevel, TopicState

  proc topicStateIMPL(topicName: static[string]): ptr TopicSettings =
    # Nim's GC safety analysis gets confused by the global variables here
    {.gcsafe.}:
      var topic {.global.}: TopicSettings
      var dummy {.global, used.} = registerTopic(topicName, addr(topic))
      return addr(topic)

  proc runtimeTopicFilteringCode*(logLevel: LogLevel, topics: seq[string]): NimNode =
    # This proc generates the run-time code used for topic filtering.
    # Each logging statement has a statically known list of associated topics.
    # For each of the topics in the list, we consult a global TopicState value
    # created in topicStateIMPL. `break chroniclesLogStmt` exits a named
    # block surrounding the entire log statement.
    result = newStmtList()
    var
      topicStateIMPL = bindSym("topicStateIMPL")
      topicsMatch = bindSym("topicsMatch")

    var topicsArray = newTree(nnkBracket)
    for topic in topics:
      topicsArray.add newCall(topicStateIMPL, newLit(topic))

    result.add quote do:
      let `chroniclesTopicsMatchVar` = `topicsMatch`(LogLevel(`logLevel`), `topicsArray`)
      if `chroniclesTopicsMatchVar` == 0:
        break `chroniclesBlockName`
else:
  template runtimeFilteringDisabledError =
    {.error: "Run-time topic filtering is currently disabled. " &
             "You can enable it by specifying '-d:chronicles_runtime_filtering:on'".}

  template setTopicState*(name, state) = runtimeFilteringDisabledError
  template setLogLevel*(name, state) = runtimeFilteringDisabledError

type InstInfo = tuple[filename: string, line: int, column: int]

when compileOption("threads"):
  # With threads turned on, we give the thread id
  # TODO: Does this make sense on all platforms? On linux, conveniently, the
  #       process id is the thread id of the `main` thread..
  proc getLogThreadId*(): int = getThreadId()
else:
  # When there are no threads, we show the process id instead, allowing easy
  # correlation on multiprocess systems
  when defined(posix):
    import posix
    proc getLogThreadId*(): int = int(posix.getpid())
  elif defined(windows):
    proc getCurrentProcessId(): uint32 {.
      stdcall, dynlib: "kernel32", importc: "GetCurrentProcessId".}
    proc getLogThreadId*(): int = int(getCurrentProcessId())
  else:
    proc getLogThreadId*(): int = 0

template formatItIMPL*(value: any): auto =
  value

template formatIt*(T: type, body: untyped) {.dirty.} =
  template formatItIMPL*(it: T): auto = body

template expandItIMPL*[R](record: R, field: static string, value: any) =
  mixin setProperty, formatItIMPL
  setProperty(record, field, formatItIMPL(value))

macro expandIt*(T: type, expandedProps: untyped): untyped =
  let
    setProperty = bindSym("setProperty", brForceOpen)
    formatItIMPL = bindSym("formatItIMPL", brForceOpen)
    expandItIMPL = id("expandItIMPL", true)
    record = ident "record"
    it = ident "it"
    it_name = ident "it_name"
    setPropertyCalls = newStmtList()

  for prop in expandedProps:
    if prop.kind != nnkAsgn:
      error "An `expandIt` definition should consist only of key-value assignments", prop

    var key = prop[0]
    let value = prop[1]
    case key.kind
    of nnkAccQuoted:
      proc toStrLit(n: NimNode): NimNode =
        let nAsStr = $n
        if nAsStr == "it": it_name
        else: newLit(nAsStr)

      if key.len < 2:
        key = key.toStrLit
      else:
        var concatCall = infix(key[0].toStrLit, "&", key[1].toStrLit)
        for i in 2 ..< key.len:
          concatCall = infix(concatCall, "&", key[i].toStrLit)
        key = newTree(nnkStaticExpr, concatCall)

    of nnkIdent, nnkSym:
      key = newLit($key)

    else:
      error &"Unexpected AST kind for an `epxpandIt` key: {key.kind} ", key

    setPropertyCalls.add quote do:
      `setProperty` `record`, `key`, `formatItIMPL`(`value`)

  result = quote do:
    template `expandItIMPL`(`record`: auto, `it_name`: static string, `it`: `T`) =
      `setPropertyCalls`

  when defined(debugLogImpl):
    echo result.repr

macro logIMPL(lineInfo: static InstInfo,
              Stream: typed,
              RecordType: type,
              eventName: static[string],
              severity: static[LogLevel],
              scopes: typed,
              logStmtBindings: varargs[untyped]): untyped =
  if not loggingEnabled: return
  clearEmptyVarargs logStmtBindings

  # First, we merge the lexical bindings with the additional
  # bindings passed to the logging statement itself:
  let lexicalBindings = scopes.finalLexicalBindings
  var finalBindings = initOrderedTable[string, NimNode]()

  for k, v in assignments(logStmtBindings, acLogStatement):
    finalBindings[k] = v

  for k, v in assignments(lexicalBindings, acLogStatement):
    finalBindings[k] = v

  # This is the compile-time topic filtering code, which has a similar
  # logic to the generated run-time filtering code:
  var enabledTopicsMatch = enabledTopics.len == 0 and severity >= enabledLogLevel
  var requiredTopicsCount = requiredTopics.len
  var topicsNode = newLit("")
  var activeTopics: seq[string] = @[]
  var useLineNumbers = lineNumbersEnabled
  var useThreadIds = threadIdsEnabled

  if finalBindings.hasKey("topics"):
    topicsNode = finalBindings["topics"]
    finalBindings.del("topics")

    if topicsNode.kind notin {nnkStrLit, nnkTripleStrLit}:
      error "Please specify the 'topics' list as a space separated string literal", topicsNode

    activeTopics = topicsNode.strVal.split({','} + Whitespace)

    for t in activeTopics:
      if t in disabledTopics:
        return
      else:
        for topic in enabledTopics:
          if topic.name == t:
            if topic.logLevel != LogLevel.DEFAULT:
              if severity >= topic.logLevel:
                enabledTopicsMatch = true
            elif severity >= enabledLogLevel:
              enabledTopicsMatch = true
        if t in requiredTopics:
          dec requiredTopicsCount

  if requiredTopicsCount > 0:
    return

  if enabledTopics.len > 0 and not enabledTopicsMatch:
    return

  proc lookForScopeOverride(option: var bool, overrideName: string) =
    if finalBindings.hasKey(overrideName):
      let overrideValue = $finalBindings[overrideName]
      if overrideValue notin ["true", "false"]:
        error(overrideName & " should be set to either true or false",
              finalBindings[overrideName])
      option = overrideValue == "true"
      finalBindings.del(overrideName)

  # The user is allowed to override the compile-time options for line numbers
  # and thread ids in particular log statements or scopes:
  lookForScopeOverride(useLineNumbers, "chroniclesLineNumbers")
  lookForScopeOverride(useThreadIds, "chroniclesThreadIds")

  var
    code = newStmtList()
    bindingLets = newTree(nnkLetSection)

  when runtimeFilteringEnabled:
    if severity != LogLevel.NONE:
      code.add runtimeTopicFilteringCode(severity, activeTopics)

  # The rest of the code selects the active LogRecord type (which can
  # be a tuple when the sink has multiple destinations) and then
  # translates the log statement to a set of calls to `initLogRecord`,
  # `setProperty` and `flushRecord`.
  let
    record = genSym(nskVar, "record")
    recordTypeSym = skipTypedesc(RecordType.getTypeImpl())
    recordTypeNodes = recordTypeSym.getTypeImpl()
    recordArity = if recordTypeNodes.kind != nnkTupleConstr: 1
                  else: recordTypeNodes.len
    expandItIMPL = bindSym("expandItIMPL", brForceOpen)

  const
    letVarsPrefix = "chronicles_"

  template addLetVar(name: string, value: NimNode) =
    bindingLets.add newTree(
      nnkIdentDefs,
        ident(letVarsPrefix & name),
        newNimNode(nnkEmpty),
        value)

  for k, v in finalBindings:
    addLetVar k, v

  if useThreadIds:
    addLetVar "tid", newCall(bindSym "getLogThreadId")

  if useLineNumbers:
    addLetVar "src", newLit(lineInfo.filename & ":" & $lineInfo.line)

  code.add quote do:
    var `record`: `RecordType`
    `bindingLets`

  for i in 0 ..< recordArity:
    let recordRef = if recordArity == 1: record
                    else: newTree(nnkBracketExpr, record, newLit(i))

    var perSinkStmtList = code
    if runtimeFilteringEnabled and recordArity > 1:
      perSinkStmtList = newStmtList()
      let sinkBit = newLit(1 shl i)
      let sinkFilterCondition = quote do:
        if (`chroniclesTopicsMatchVar` and `sinkBit`) != 0:
          discard
      sinkFilterCondition[0][1] = perSinkStmtList
      code.add sinkFilterCondition

    perSinkStmtList.add quote do:
      prepareOutput(`recordRef`, LogLevel(`severity`))
      initLogRecord(`recordRef`, LogLevel(`severity`), `topicsNode`, `eventName`)

    for i in 0 ..< bindingLets.len:
      let letVar = bindingLets[i][0]
      perSinkStmtList.add newCall(
        expandItIMPL,
        recordRef,
        newLit(substr($letVar, len(letVarsPrefix))),
        letVar)

    perSinkStmtList.add newCall("logAllDynamicProperties", Stream, record, newLit(i))
    perSinkStmtList.add newCall("flushRecord", recordRef)

  result = quote do:
    try:
      block `chroniclesBlockName`:
        `code`
    except CatchableError as err:
      logLoggingFailure(`eventName`, err)

  when defined(debugLogImpl):
    echo result.repr

# Translate all the possible overloads to `logIMPL`:
template log*(lineInfo: static InstInfo,
              severity: static[LogLevel],
              eventName: static[string],
              props: varargs[untyped]) {.dirty.} =

  bind logIMPL, bindSym, brForceOpen
  logIMPL(lineInfo, activeChroniclesStream(),
          Record(activeChroniclesStream()), eventName, severity,
          bindSym("activeChroniclesScope", brForceOpen), props)

template log*(lineInfo: static InstInfo,
              stream: type,
              severity: static[LogLevel],
              eventName: static[string],
              props: varargs[untyped]) {.dirty.} =

  bind logIMPL, bindSym, brForceOpen
  logIMPL(lineInfo, stream, stream.Record, eventName, severity,
          bindSym("activeChroniclesScope", brForceOpen), props)

template wrapSideEffects(debug: bool, body: untyped) {.inject.} =
  when debug:
    {.noSideEffect.}:
      try: body
      except: discard
  else:
    body

template logFn(name: untyped, severity: typed, debug=false) {.dirty.} =
  bind log, wrapSideEffects

  template `name`*(eventName: static[string], props: varargs[untyped]) {.dirty.} =
    wrapSideEffects(debug):
      log(instantiationInfo(), severity, eventName, props)

  template `name`*(stream: type, eventName: static[string], props: varargs[untyped]) {.dirty.} =
    wrapSideEffects(debug):
      log(instantiationInfo(), stream, severity, eventName, props)

# workaround for https://github.com/status-im/nim-chronicles/issues/92
when defined(windows) and (NimMajor, NimMinor, NimPatch) < (1, 4, 4):
  logFn trace , LogLevel.TRACE, debug=true
  logFn debug , LogLevel.DEBUG, debug=true
  logFn info  , LogLevel.INFO, debug=true
  logFn notice, LogLevel.NOTICE, debug=true
  logFn warn  , LogLevel.WARN, debug=true
  logFn error , LogLevel.ERROR, debug=true
  logFn fatal , LogLevel.FATAL, debug=true
else:
  logFn trace , LogLevel.TRACE, debug=true
  logFn debug , LogLevel.DEBUG
  logFn info  , LogLevel.INFO
  logFn notice, LogLevel.NOTICE
  logFn warn  , LogLevel.WARN
  logFn error , LogLevel.ERROR
  logFn fatal , LogLevel.FATAL

# TODO:
#
# * extract the compile-time conf framework in confutils
# * instance carried streams that can collect the information in memory
#
# * define an alternative format strings API (.net style)
# * auto-derived topics based on nimble package name and module name
#
# * Android and iOS logging, mixed std streams (logging both to stdout and stderr?)
# * dynamic scope overrides (plus maybe an option to control the priority
#                            between dynamic and lexical bindings)
#
# * implement some of the leading standardized structured logging formats
#

