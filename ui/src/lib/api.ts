// The only place the client talks to the server. Every response is a versioned
// fm-dashboard-api.v1 envelope carrying its own provenance and freshness, so a
// view never has to guess how old an answer is or where it came from.
const BASE = "/api/v1"

export type Envelope<T> = {
  schema: "fm-dashboard-api.v1"
  resource: string
  generation: number
  home: string | null
  collected_at: string | null
  observed_at: string | null
  age_seconds: number | null
  upstream: { schema?: string | null; generated?: string | null }
  sources: string[]
  data: T
}

export class ApiError extends Error {
  status: number
  constructor(message: string, status: number) {
    super(message)
    this.status = status
  }
}

export async function fetchResource<T>(resource: string, signal?: AbortSignal): Promise<Envelope<T>> {
  let res: Response
  try {
    res = await fetch(`${BASE}/${resource}`, { signal, headers: { accept: "application/json" } })
  } catch (err) {
    if (err instanceof DOMException && err.name === "AbortError") throw err
    throw new ApiError("the dashboard server is not reachable", 0)
  }
  let body: unknown = null
  try {
    body = await res.json()
  } catch {
    throw new ApiError("the server returned an unreadable response", res.status)
  }
  if (!res.ok) {
    const detail = (body as { error?: string } | null)?.error
    throw new ApiError(detail ?? `request failed (${res.status})`, res.status)
  }
  const doc = body as Envelope<T> | null
  if (!doc || doc.schema !== "fm-dashboard-api.v1") {
    throw new ApiError("the server returned an unrecognised document", res.status)
  }
  return doc
}

export type LinkState = "connecting" | "live" | "live-dev" | "reconnecting" | "offline"

// Live updates. The server pushes only a generation number; the client refetches
// what it is actually showing. A missed event costs one stale render, never a
// wrong one.
export function subscribe(
  onChange: () => void,
  onState: (s: LinkState) => void,
): () => void {
  let source: EventSource | null = null
  let closed = false
  let retry: number | undefined

  const open = () => {
    if (closed) return
    try {
      source = new EventSource(`${BASE}/stream`)
    } catch {
      onState("offline")
      return
    }
    source.addEventListener("hello", (e) => {
      onState("live")
      try {
        if (JSON.parse((e as MessageEvent).data)?.dev_reload) onState("live-dev")
      } catch {
        /* a malformed hello still means the stream is up */
      }
    })
    source.addEventListener("evidence", () => onChange())
    source.onerror = () => {
      onState("reconnecting")
      source?.close()
      source = null
      if (!closed) retry = window.setTimeout(open, 3000)
    }
  }
  open()
  return () => {
    closed = true
    if (retry) window.clearTimeout(retry)
    source?.close()
  }
}
