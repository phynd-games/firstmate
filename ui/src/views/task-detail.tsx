import { Dot, EmptyPanel, ErrorPanel, LoadingPanel, Mono, SectionTitle, ToneBadge, Unavailable } from "@/components/primitives"
import { useResource } from "@/lib/use-resource"
import { dash, stateTone } from "@/lib/format"
import type { TaskRow } from "@/lib/types"

type EventLine = { verb: string; note: string; raw: string }
type Events = { readable: boolean; reason: string | null; total: number; shown: number; truncated: number; path: string; lines: EventLine[] }

const verbTone = (v: string) => {
  switch (v.toLowerCase()) {
    case "done": case "resolved": return "ok" as const
    case "failed": case "blocked": return "critical" as const
    case "needs-decision": return "serious" as const
    case "paused": return "warn" as const
    case "working": return "info" as const
    default: return "idle" as const
  }
}

export function TaskDetail({ id, generation, onOpenReport }: {
  id: string
  generation: number
  onOpenReport?: (reportId: string) => void
}) {
  const r = useResource<{
    task: TaskRow & {
      current_state?: { state?: string | null; source?: string | null; detail?: string | null; observed_at?: string | null; freshness?: string | null }
      paths?: Record<string, { path?: string | null; present?: boolean; available?: boolean; reason?: string | null }>
      hints?: { open_decisions?: { key?: string; verb?: string; summary?: string }[] }
    }
    events: Events
  }>(
    `tasks/${encodeURIComponent(id)}`, generation)
  if (r.error) return <ErrorPanel title="This worker could not be loaded" detail={r.error} />
  if (r.loading && !r.doc) return <LoadingPanel rows={5} />
  if (!r.doc) return <EmptyPanel>No record returned for this worker.</EmptyPanel>
  const { task, events } = r.doc.data
  const decisions = task.hints?.open_decisions ?? task.open_decisions ?? []
  const report = task.paths?.report
  // The single-task document returns the canonical snapshot row, which nests
  // current_state; the list document flattens it. Read either shape rather than
  // rendering dashes for a state the server did supply.
  const cs = task.current_state ?? {
    state: task.state, source: task.state_source, detail: task.state_detail,
    observed_at: task.observed_at, freshness: task.freshness,
  }

  return (
    <div className="space-y-4">
      <div className="rounded border border-border bg-muted/30 p-3">
        <p className="text-[10px] uppercase tracking-[0.12em] text-muted-foreground">current state — reconciled</p>
        <p className="mt-1 flex items-center gap-2 text-sm font-semibold">
          <Dot tone={stateTone(cs.state)} />
          {dash(cs.state)} <span className="font-normal text-muted-foreground">via {dash(cs.source)}</span>
        </p>
        <p className="text-xs text-muted-foreground">{dash(cs.detail)}</p>
        <p className="text-[11px] text-muted-foreground">observed {dash(cs.observed_at)} ({dash(cs.freshness)})</p>
      </div>

      <dl className="grid grid-cols-[104px_1fr] gap-x-3 gap-y-1.5 text-xs">
        <dt className="text-muted-foreground">runtime</dt>
        <dd className="font-mono">{dash(task.harness)} / {dash(task.model)} / {dash(task.effort)}</dd>
        <dt className="text-muted-foreground">delivery</dt>
        <dd>{dash(task.mode)} — captain merges: {task.yolo === "on" ? "no" : "yes"}</dd>
        <dt className="text-muted-foreground">herdr</dt>
        <dd className="font-mono">
          {task.endpoint?.available === false
            ? <Unavailable reason={task.endpoint.reason} />
            : `${dash(task.backend)} · ${dash(task.endpoint?.target)} · ${
                task.endpoint?.exists === true ? "present" : task.endpoint?.exists === false ? "absent" : "unknown"}`}
        </dd>
        <dt className="text-muted-foreground">pull request</dt>
        <dd>
          {task.pr?.available === false
            ? <Unavailable reason={task.pr.reason} />
            : task.pr?.url
              ? <a href={task.pr.url} target="_blank" rel="noreferrer noopener"
                  className="font-mono text-fm-info hover:underline">{task.pr.url}</a>
              : "none recorded"}
        </dd>
        <dt className="text-muted-foreground">report</dt>
        <dd>
          {report?.available === false ? <Unavailable reason={report.reason} />
            : report?.present && report.path
              ? (onOpenReport
                  ? <button type="button" onClick={() => onOpenReport(id)}
                      className="text-fm-info hover:underline">open this worker's report</button>
                  : <Mono>{report.path}</Mono>)
              : "none written"}
        </dd>
      </dl>

      {decisions.length ? (
        <div className="space-y-2">
          <SectionTitle>Open captain's calls</SectionTitle>
          {decisions.map((d, i) => (
            <div key={i} className="rounded border border-fm-serious/40 bg-fm-serious/10 p-2.5">
              <div className="flex items-center gap-2">
                <ToneBadge tone="serious">{dash(d.verb ?? "open")}</ToneBadge>
                <Mono>{dash(d.key)}</Mono>
              </div>
              <p className="mt-1 text-xs">{dash(d.summary)}</p>
            </div>
          ))}
        </div>
      ) : null}

      <div className="space-y-2">
        <SectionTitle aside={events?.readable ? `${events.shown} of ${events.total}` : undefined}>
          Event history — history, not current state
        </SectionTitle>
        {!events?.readable ? (
          <EmptyPanel><Unavailable reason={events?.reason ?? "No event history recorded."} /></EmptyPanel>
        ) : events.lines.length === 0 ? (
          <EmptyPanel>No events recorded yet.</EmptyPanel>
        ) : (
          <ul className="divide-y divide-border rounded border border-border">
            {[...events.lines].reverse().map((l, i) => (
              <li key={i} className="flex items-start gap-2 px-2.5 py-1.5">
                <ToneBadge tone={verbTone(l.verb)}>{dash(l.verb)}</ToneBadge>
                <span className="min-w-0 flex-1 text-xs">{dash(l.note || l.raw)}</span>
              </li>
            ))}
          </ul>
        )}
        {events?.truncated ? (
          <p className="text-[11px] text-fm-warn">{events.truncated} older events not shown by the read bound.</p>
        ) : null}
        {events?.path ? <Mono>{events.path}</Mono> : null}
      </div>
    </div>
  )
}
