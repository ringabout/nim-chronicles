import
  options, log_output

when not defined(js):
  import
    faststreams/outputs,
    json_serialization

  export
    outputs, json_serialization

  type
    LogRecord*[Output; timestamps: static[TimestampScheme]] = object
      output*: OutputStream
      jsonWriter: JsonWriter

  template setProperty(r: var LogRecord, key: string, val: auto) =
    writeField(r.jsonWriter, key, val)

  template flushRecord*(r: var LogRecord) =
    r.jsonWriter.endRecord()
    r.output.write '\n'
    flushOutput r.output

else:
  import
    jscore, jsconsole, jsffi

  export
    convertToConsoleLoggable

  type
    JsonString* = distinct string

  type
    LogRecord*[Output; timestamps: static[TimestampScheme]] = object
      output*: Output
      record: js

  template setProperty*(r: var LogRecord, key: string, val: auto) =
    r.record[key] = when val is string: cstring(val) else: val

  proc flushRecord*(r: var LogRecord) =
    r.output.append JSON.stringify(r.record)
    flushOutput r.output

proc initLogRecord*(r: var LogRecord,
                    level: LogLevel,
                    topics: string,
                    msg: string) =
  when defined(js):
    r.record = newJsObject()
  else:
    r.jsonWriter = JsonWriter.init(r.output, pretty = false)
    r.jsonWriter.beginRecord()

  if level != NONE:
    setProperty(r, "lvl", level.shortName)

  when r.timestamps != NoTimestamps:
    when not defined(js):
      r.jsonWriter.writeFieldName("ts")
      when r.timestamps == RfcTime: w.stream.write '"'
      r.writeTs()
      when r.timestamps == RfcTime: w.stream.write '"'
    else:
      setProperty(r, "ts", r.timestamp())

  setProperty(r, "msg", msg)

  if topics.len > 0:
    setProperty(r, "topics", topics)

template setFirstProperty*(r: LogRecord, key: string, val: auto) =
  setProperty(r, key, val)

