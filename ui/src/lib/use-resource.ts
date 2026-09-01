import { useEffect, useState } from "react"
import { ApiError, fetchResource, type Envelope } from "./api"

export type Resource<T> = {
  doc: Envelope<T> | null
  error: string | null
  loading: boolean
}

// The stream only says "something changed"; this refetches what the view is
// actually showing. Loading always resolves: either data, or a concrete error
// with a reason - never an indefinite "reading…" surface.
export function useResource<T>(resource: string | null, generation: number): Resource<T> {
  const [state, setState] = useState<Resource<T>>({ doc: null, error: null, loading: true })
  useEffect(() => {
    if (!resource) return
    const ctl = new AbortController()
    let alive = true
    setState((s) => ({ ...s, loading: true }))
    fetchResource<T>(resource, ctl.signal)
      .then((doc) => alive && setState({ doc, error: null, loading: false }))
      .catch((err: unknown) => {
        if (err instanceof DOMException && err.name === "AbortError") return
        if (!alive) return
        const message = err instanceof ApiError ? err.message : String(err)
        setState({ doc: null, error: message, loading: false })
      })
    return () => {
      alive = false
      ctl.abort()
    }
  }, [resource, generation])
  return state
}
