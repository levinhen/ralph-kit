// Ralph agent stream reader.
//
// Reads the NDJSON event stream a coding agent CLI writes to stdout and turns it
// into five things, all inside this one process:
//
//   1. framing      - one line -> one event, tolerating non-JSON CLI noise
//   2. liveness     - a heartbeat counter Ralph's watchdog polls
//   3. display      - a compact human-readable log on stderr
//   4. accounting   - normalised token usage and a cost for the invocation
//   5. diagnostics  - a bounded ring of raw events plus a summary for the caller
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

const SUPPORTED_TOOLS = ['claude', 'codex', 'pi']
const RING_LIMIT = 100
// The only consumer is wait_for_active_tool, which polls on a 2s sleep against a
// 360s idle timeout. Anything below that poll interval guarantees a fresh value
// between two polls; going faster just burns writes nobody can observe.
const ACTIVITY_FLUSH_MS = 1000
const RATE_LIMIT_PATTERN =
  /(^|\D)429(\D|$)|too many requests|rate[-_ ]?limit(ed|ing)?|quota exceeded/i

// Token accounting.
//
// All three CLIs report usage, but neither the shape nor the meaning of "input"
// matches:
//
//   claude  result.usage        input_tokens EXCLUDES cache reads and writes,
//                               which are reported in their own fields. The
//                               event also carries total_cost_usd - the CLI's
//                               own bill - so Ralph never prices Claude itself.
//   codex   turn.completed.usage  input_tokens INCLUDES cached_input_tokens and
//                               cache_write_input_tokens (the OpenAI convention),
//                               and no cost is reported at all, so Ralph has to
//                               price it from a rate table.
//   pi      message.usage       input EXCLUDES cacheRead/cacheWrite, and
//                               usage.cost.total is pi's own catalogue-priced
//                               bill for the model it actually ran, so Ralph
//                               takes that number instead of its rate table.
//
// Everything below is normalised into the same four buckets, where `input`
// always means new, uncached input.
//
// Rates are USD per million tokens, which makes the arithmetic exact in
// integers: rate * tokens is already the cost in micro-USD (1e-6 USD), the unit
// the whole accounting chain uses so the bash side can sum it without floats.
//
// Defaults are the gpt-5.6-sol standard tier (codex's default model): $5 input,
// $0.50 cached input, $6.25 cache writes (1.25x input), $30 output. Prompts over
// 272K input tokens bill at 2x input / 1.5x output for the entire request; the
// stream reports one aggregate per turn, so that tier cannot be detected here -
// override the rates if a run lives in it.
const PRICE_DEFAULTS = {
  input: 5,
  cached: 0.5,
  cacheWrite: 6.25,
  output: 30,
}

function envRate(name, fallback) {
  const raw = process.env[name]
  if (raw === undefined || raw.trim() === '') return fallback
  const value = Number(raw)
  return Number.isFinite(value) && value >= 0 ? value : fallback
}

const PRICE = {
  input: envRate('RALPH_PRICE_INPUT_USD', PRICE_DEFAULTS.input),
  cached: envRate('RALPH_PRICE_CACHED_INPUT_USD', PRICE_DEFAULTS.cached),
  cacheWrite: envRate('RALPH_PRICE_CACHE_WRITE_USD', PRICE_DEFAULTS.cacheWrite),
  output: envRate('RALPH_PRICE_OUTPUT_USD', PRICE_DEFAULTS.output),
}

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

if (!SUPPORTED_TOOLS.includes(options.tool)) {
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

const usage = { input: 0, cached: 0, cacheWrite: 0, output: 0 }
let costMicros = 0
// True only when the CLI reported the money itself. Ralph shows an estimate
// differently from a bill, so this flag has to survive into the summary.
let costExact = false
let modelLabel = ''

let activityFlushedAt = 0

function tokenCount(value) {
  const count = Number(value)
  return Number.isFinite(count) && count > 0 ? Math.round(count) : 0
}

function addUsage(buckets) {
  usage.input += buckets.input
  usage.cached += buckets.cached
  usage.cacheWrite += buckets.cacheWrite
  usage.output += buckets.output
}

function priceMicros(buckets) {
  return Math.round(
    buckets.input * PRICE.input +
      buckets.cached * PRICE.cached +
      buckets.cacheWrite * PRICE.cacheWrite +
      buckets.output * PRICE.output,
  )
}

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
  const now = Date.now()
  if (!force && now - activityFlushedAt < ACTIVITY_FLUSH_MS) return
  activityFlushedAt = now
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

// codex reports one aggregate per completed turn, and `exec` normally produces a
// single turn per invocation. Summing rather than replacing keeps the numbers
// right if a future version splits an invocation across several turns.
function recordCodexUsage(event) {
  const reported = event.usage
  if (!reported || typeof reported !== 'object') return

  const total = tokenCount(reported.input_tokens)
  const cached = tokenCount(reported.cached_input_tokens)
  const cacheWrite = tokenCount(reported.cache_write_input_tokens)
  const buckets = {
    // input_tokens is the whole prompt, so the billed-at-full-rate remainder is
    // what is left once the cache hits and writes are taken out of it.
    input: Math.max(0, total - cached - cacheWrite),
    cached,
    cacheWrite,
    // reasoning_output_tokens is already part of output_tokens.
    output: tokenCount(reported.output_tokens),
  }

  addUsage(buckets)
  costMicros += priceMicros(buckets)
}

function recordClaudeUsage(event) {
  const reported = event.usage
  if (reported && typeof reported === 'object') {
    addUsage({
      input: tokenCount(reported.input_tokens),
      cached: tokenCount(reported.cache_read_input_tokens),
      cacheWrite: tokenCount(reported.cache_creation_input_tokens),
      output: tokenCount(reported.output_tokens),
    })
  }

  const cost = Number(event.total_cost_usd)
  if (Number.isFinite(cost) && cost >= 0) {
    // USD -> micro-USD, the integer unit the rest of the chain sums in.
    costMicros += Math.round(cost * 1e6)
    costExact = true
  }
}

// pi reports usage per message, and only assistant messages (plus a sub-agent's
// toolResult) carry one. message_end is the single place each usage object
// appears exactly once - turn_end and agent_end both repeat messages that were
// already reported there.
function recordPiUsage(message) {
  const reported = message.usage
  if (!reported || typeof reported !== 'object') return

  addUsage({
    input: tokenCount(reported.input),
    cached: tokenCount(reported.cacheRead),
    cacheWrite: tokenCount(reported.cacheWrite),
    output: tokenCount(reported.output),
  })

  // pi prices the model it actually ran from its own catalogue, so this is a
  // reported bill rather than something Ralph's rate table has to guess at.
  const cost = Number(reported.cost?.total)
  if (Number.isFinite(cost) && cost >= 0) {
    costMicros += Math.round(cost * 1e6)
    costExact = true
  }
}

// pi passes structured tool args, so the useful half of a one-line log entry is
// whichever field names the target. Anything else degrades to the tool name.
const PI_TOOL_HINT_KEYS = ['command', 'path', 'file_path', 'pattern', 'query']

function piToolHint(args) {
  if (!args || typeof args !== 'object') return ''

  for (const key of PI_TOOL_HINT_KEYS) {
    const value = args[key]
    if (typeof value !== 'string' || value === '') continue
    const firstLine = value.split('\n', 1)[0]
    return firstLine.length > 160 ? `${firstLine.slice(0, 157)}...` : firstLine
  }

  return ''
}

// pi keeps the stream open across its own auto-retries, so whether the
// invocation landed is decided by the last assistant message, not the first.
let piLastStopReason = ''

function transformPi(event) {
  const lines = []

  switch (event.type) {
    case 'session':
      lines.push(`[pi session: ${event.id ?? '?'}]`)
      break
    case 'message_end': {
      const message = event.message || {}
      if (message.role !== 'assistant') break

      recordPiUsage(message)

      // Unlike codex, pi names the model it resolved on every assistant
      // message, so the label is the real one rather than a priced-for guess.
      if (!modelLabel && typeof message.model === 'string' && message.model !== '') {
        modelLabel = message.model
      }

      piLastStopReason = typeof message.stopReason === 'string' ? message.stopReason : ''
      if (piLastStopReason === 'error' || piLastStopReason === 'aborted') {
        const detail = errorText({ message: message.errorMessage }, `assistant turn ${piLastStopReason}`)
        errorTexts.push(detail)
        sawFailure = true
        lines.push(`[${piLastStopReason}] ${detail}`)
      }

      if (Array.isArray(message.content)) {
        for (const block of message.content) {
          if (block?.type === 'text' && block.text) {
            assistantChunks.push(block.text)
            lines.push(block.text)
          }
        }
      }
      break
    }
    case 'tool_execution_start': {
      const name = event.toolName ?? 'tool'
      const hint = piToolHint(event.args)
      lines.push(hint ? `· ${name}: ${hint}` : `· ${name}`)
      break
    }
    case 'compaction_start':
      lines.push('[compacting context]')
      break
    case 'auto_retry_start': {
      const detail = errorText({ message: event.errorMessage }, 'transient error')
      // Kept in errorTexts so a 429 pi retried into a failure is still visible
      // to the rate-limit check, which only fires on a non-zero exit anyway.
      errorTexts.push(detail)
      lines.push(`[retry ${event.attempt ?? '?'}/${event.maxAttempts ?? '?'}] ${detail}`)
      break
    }
    case 'agent_end':
      if (event.willRetry === true) break
      if (piLastStopReason === 'error' || piLastStopReason === 'aborted') {
        sawFailure = true
        lines.push(`[failed: ${piLastStopReason}]`)
      } else {
        sawCompletion = true
        lines.push('[done]')
      }
      break
    default:
      break
  }

  return lines
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
      recordCodexUsage(event)
      lines.push('[done]')
      break
    default:
      break
  }

  return lines
}

function transformClaude(event) {
  const lines = []

  // The init event is the only place the resolved model name appears before the
  // run ends; later system events carry a null model, so never overwrite it.
  if (event.type === 'system') {
    if (!modelLabel && typeof event.model === 'string' && event.model !== '') {
      modelLabel = event.model
    }
    return lines
  }

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
    recordClaudeUsage(event)
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

const TRANSFORMS = {
  claude: transformClaude,
  codex: transformCodex,
  pi: transformPi,
}

const transform = TRANSFORMS[options.tool]

// codex never names its model in the event stream, so the label is whatever the
// rate table is priced for. Claude fills this in from its own init event.
if (options.tool === 'codex') {
  modelLabel = process.env.RALPH_PRICE_MODEL?.trim() || 'gpt-5.6-sol'
}

function writeSummary() {
  // claude streams one chunk per text block of a single message; codex and pi
  // hand over whole messages, which have to stay separated to stay readable.
  const assistantText = assistantChunks.join(options.tool === 'claude' ? '' : '\n\n')
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
      usage: { ...usage, total: usage.input + usage.cached + usage.cacheWrite + usage.output },
      costMicros,
      costExact,
      model: modelLabel,
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
