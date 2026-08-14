// Ralph agent stream reader.
//
// Reads the NDJSON event stream a coding agent CLI writes to stdout and turns it
// into four things, all inside this one process:
//
//   1. framing      - one line -> one event, tolerating non-JSON CLI noise
//   2. liveness     - a heartbeat counter Ralph's watchdog polls
//   3. display      - a compact human-readable log on stderr
//   4. diagnostics  - a bounded ring of raw events plus a summary for the caller
//
// Keeping all four in one process is the point. The previous shell version split
// them across a bash loop, a FIFO, and a jq child, which meant a dead formatter
// took the reader down with it (SIGPIPE on the FIFO write) and the heartbeat had
// to travel through a file. Everything here is a function call instead.
//
// stdin is an anonymous pipe, never a FIFO: on Git Bash only a Cygwin process
// can be the reader side of a mkfifo, so the caller keeps a `cat` in front of us.

import { createInterface } from 'node:readline'
import { writeFileSync, renameSync } from 'node:fs'

const RING_LIMIT = 100
const ACTIVITY_FLUSH_MS = 200
const RATE_LIMIT_PATTERN =
  /(^|\D)429(\D|$)|too many requests|rate[-_ ]?limit(ed|ing)?|quota exceeded/i

function parseArgs(argv) {
  const options = {
    tool: '',
    activityFile: '',
    summaryFile: '',
    diagnosticFile: '',
  }
  const keys = {
    '--tool': 'tool',
    '--activity-file': 'activityFile',
    '--summary-file': 'summaryFile',
    '--diagnostic-file': 'diagnosticFile',
  }

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i]
    const eq = arg.indexOf('=')
    const name = eq === -1 ? arg : arg.slice(0, eq)
    const key = keys[name]
    if (!key) continue
    if (eq === -1) {
      options[key] = argv[i + 1] ?? ''
      i += 1
    } else {
      options[key] = arg.slice(eq + 1)
    }
  }

  return options
}

const options = parseArgs(process.argv.slice(2))

if (options.tool !== 'claude' && options.tool !== 'codex') {
  process.stderr.write(`stream-agent: unsupported --tool '${options.tool}'\n`)
  process.exit(2)
}

// Losing the pretty log must never take the reader down: without these, a closed
// stderr raises EPIPE and kills this process mid-stream, which is exactly the
// failure the shell version had.
process.stderr.on('error', () => {})
process.stdout.on('error', () => {})

const ring = new Array(RING_LIMIT)
let ringIndex = 0
let ringCount = 0

let eventCount = 0
let parseErrorCount = 0
let sawCompletion = false
let sawFailure = false

const errorTexts = []
const assistantChunks = []

let activityFlushedAt = 0
let activityDirty = false

function writeDisplay(text) {
  if (text === undefined || text === null || text === '') return
  process.stderr.write(`${text}\n`)
}

function writeFileAtomic(path, contents) {
  if (!path) return
  try {
    const temp = `${path}.tmp`
    writeFileSync(temp, contents)
    renameSync(temp, path)
  } catch {
    // Diagnostics are best-effort; never fail the run over them.
  }
}

// The watchdog in process.sh polls this counter to decide whether the tool is
// still alive. Only parsed events bump it: a hung CLI spewing non-JSON noise
// must still be able to trip the idle timeout.
function touchActivity(force) {
  activityDirty = true
  const now = Date.now()
  if (!force && now - activityFlushedAt < ACTIVITY_FLUSH_MS) return
  activityFlushedAt = now
  activityDirty = false
  writeFileAtomic(options.activityFile, `${eventCount}\n`)
}

function recordRaw(line) {
  ring[ringIndex] = line
  ringIndex = (ringIndex + 1) % RING_LIMIT
  if (ringCount < RING_LIMIT) ringCount += 1
}

function ringLines() {
  const start = ringCount < RING_LIMIT ? 0 : ringIndex
  const lines = []
  for (let i = 0; i < ringCount; i += 1) {
    lines.push(ring[(start + i) % RING_LIMIT])
  }
  return lines
}

// Mirrors the old jq `error_text` helper: the message hides in one of three
// shapes depending on which layer of the CLI produced it.
function errorText(event, fallback) {
  if (event.message !== undefined && event.message !== null) return String(event.message)
  const error = event.error
  if (error && typeof error === 'object') {
    if (error.message !== undefined && error.message !== null) return String(error.message)
    try {
      return JSON.stringify(error)
    } catch {
      return fallback
    }
  }
  if (error !== undefined && error !== null) return String(error)
  return fallback
}

function transformCodex(event) {
  const lines = []
  const item = event.item || {}

  switch (event.type) {
    case 'thread.started':
      lines.push(`[codex session: ${event.thread_id ?? '?'}]`)
      break
    case 'item.started':
      if (item.type === 'command_execution') {
        lines.push(`· ${item.command ?? 'command'}`)
      } else if (item.type === 'mcp_tool_call') {
        const label = [item.server, item.tool, item.name]
          .filter((part) => part !== undefined && part !== null && part !== '')
          .join('.')
        lines.push(`· ${label}`)
      } else if (item.type === 'web_search') {
        lines.push('· web search')
      }
      break
    case 'item.completed':
      if (item.type === 'agent_message') {
        if (item.text) {
          assistantChunks.push(item.text)
          lines.push(item.text)
        }
      } else if (item.type === 'file_change') {
        lines.push('· file changes')
      }
      break
    case 'error': {
      const message = errorText(event, 'unknown error')
      errorTexts.push(message)
      sawFailure = true
      lines.push(`[error] ${message}`)
      break
    }
    case 'turn.failed': {
      const message = errorText(event, 'turn failed')
      errorTexts.push(message)
      sawFailure = true
      lines.push(`[failed] ${message}`)
      break
    }
    case 'turn.completed':
      sawCompletion = true
      lines.push('[done]')
      break
    default:
      break
  }

  return lines
}

function transformClaude(event) {
  const lines = []

  if (event.type === 'assistant') {
    const content = event.message?.content
    if (Array.isArray(content)) {
      for (const block of content) {
        if (block?.type === 'text') {
          if (block.text) {
            assistantChunks.push(block.text)
            lines.push(block.text)
          }
        } else if (block?.type === 'tool_use') {
          lines.push(`· ${block.name ?? 'tool'}`)
        }
      }
    }
    return lines
  }

  if (event.type === 'result') {
    lines.push(`[done: ${event.subtype ?? '?'}]`)
    // A failed tool call still reports subtype "success" here, so is_error is
    // the only trustworthy signal on this event.
    if (event.is_error) {
      sawFailure = true
      errorTexts.push(errorText(event, event.result ? String(event.result) : 'result reported is_error'))
    } else {
      sawCompletion = true
    }
    return lines
  }

  if (event.type === 'error') {
    const message = errorText(event, 'unknown error')
    errorTexts.push(message)
    sawFailure = true
    lines.push(`[error] ${message}`)
  }

  return lines
}

const transform = options.tool === 'codex' ? transformCodex : transformClaude

function writeSummary() {
  const assistantText = assistantChunks.join(options.tool === 'codex' ? '\n\n' : '')
  const errors = errorTexts.join('\n')
  const rateLimited =
    RATE_LIMIT_PATTERN.test(errors) ||
    RATE_LIMIT_PATTERN.test(assistantText) ||
    ringLines().some((line) => RATE_LIMIT_PATTERN.test(line))

  writeFileAtomic(
    options.summaryFile,
    `${JSON.stringify({
      tool: options.tool,
      eventCount,
      parseErrorCount,
      sawCompletion,
      sawFailure,
      rateLimited,
      assistantText,
      errorText: errors,
    })}\n`,
  )
}

async function main() {
  const input = createInterface({ input: process.stdin, crlfDelay: Infinity })

  for await (const line of input) {
    recordRaw(line)
    if (line.trim() === '') continue

    let event = null
    try {
      event = JSON.parse(line)
    } catch {
      event = null
    }

    if (event === null || typeof event !== 'object') {
      // CLI noise: upgrade notices, deprecation warnings, startup banners. Show
      // it so nothing is silently swallowed, but do not count it as a heartbeat.
      parseErrorCount += 1
      writeDisplay(line)
      continue
    }

    eventCount += 1
    touchActivity(false)

    for (const displayLine of transform(event)) {
      writeDisplay(displayLine)
    }
  }

  touchActivity(true)
  writeFileAtomic(options.diagnosticFile, `${ringLines().join('\n')}\n`)
  writeSummary()
}

main().then(
  () => process.exit(0),
  (error) => {
    process.stderr.write(`stream-agent: ${error?.message ?? error}\n`)
    // Still hand the caller whatever we managed to collect.
    try {
      writeFileAtomic(options.diagnosticFile, `${ringLines().join('\n')}\n`)
      writeSummary()
    } catch {
      // ignore
    }
    process.exit(1)
  },
)
