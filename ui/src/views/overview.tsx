import { useMemo, useState } from "react"
import { Card } from "@/components/ui/card"
import { ScrollArea } from "@/components/ui/scroll-area"
import { KpiCard } from "@/components/kpi"
import { ActivityTrendChart, CompositionChart, CountBarChart, type Slice, type TrendPoint } from "@/components/charts"
import { Dot, EmptyPanel, ErrorPanel, LoadingPanel, Mono, SectionTitle, ToneBadge, Unavailable } from "@/components/primitives"
import { useResource } from "@/lib/use-resource"
import { ago, dash, severityTone, stateTone } from "@/lib/format"
import type { BacklogRow, Metric, Overview, ReportRow, TaskRow } from "@/lib/types"
import { Input } from "@/components/ui/input"

type DeliveryRow = { task_id: string; url: string; source: string; available?: boolean; reason?: string }

const STATE_COLOR: Record<string, string> = {
  ok: "var(--fm-ok)", info: "var(--fm-info)", warn: "var(--fm-warn)",
  serious: "var(--fm-serious)", critical: "var(--fm-critical)", idle: "var(--fm-idle)",
}

// Slice colour follows the state itself, so a filter that changes which states
// are present never repaints the survivors.
const sliceColor = (state: string) =>
  state === "parked" ? "var(--fm-cat-3)"
  : state === "paused" ? "var(--fm-warn)"
  : STATE_COLOR[stateTone(state)] ?? "var(--fm-idle)"

const ALARMING = new Set(["wake_backlog", "observed_failed"])

// Work started / completed per day, built ONLY from real recorded dates. This
// home keeps no event time series, so nothing here is interpolated: a day with
// no record is a zero, and fewer than two dated days renders as unavailable
// rather than as a flat line pretending to be a trend.
function trendFrom(records: BacklogRow[]): TrendPoint[] {
  const days = new Map<string, TrendPoint>()
  const touch = (day: string) => {
    let p = days.get(day)
    if (!p) { p = { day, started: 0, completed: 0 }; days.set(day, p) }
    return p
  }
  for (const r of records) {
    if (r.since) touch(r.since).started += 1
    const done = r.completion?.date ?? r.done ?? r.merged ?? r.reported
    if (done) touch(done).completed += 1
  }
  return [...days.values()].sort((a, b) => a.day.localeCompare(b.day)).slice(-14)
}

export function OverviewView({ generation, onOpenTask, onOpenReport }: {
  generation: number
  onOpenTask: (id: string) => void
  onOpenReport: (id: string) => void
}) {
  const overview = useResource<Overview>("overview", generation)
  const tasks = useResource<{ tasks: TaskRow[] }>("tasks", generation)
  const backlog = useResource<{ records: BacklogRow[] }>("backlog", generation)
  const delivery = useResource<{ records: DeliveryRow[]; note: string }>("delivery", generation)
  const reports = useResource<{ reports: ReportRow[]; total: number; truncated: number }>("reports", generation)
  const [selected, setSelected] = useState<Metric | null>(null)
  const [reportQuery, setReportQuery] = useState("")

  const health = useMemo<Slice[]>(() => {
    const rows = tasks.doc?.data.tasks ?? []
    const counts = new Map<string, number>()
    for (const t of rows) {
      const key = t.state ?? "unknown"
      counts.set(key, (counts.get(key) ?? 0) + 1)
    }
    return [...counts.entries()].map(([name, value]) => ({
      name, value, color: sliceColor(name),
    }))
  }, [tasks.doc])

  const workMix = useMemo(() => {
    const rows = backlog.doc?.data.records ?? []
    const counts = new Map<string, number>()
    for (const r of rows) {
      const key = r.state ?? "unknown"
      counts.set(key, (counts.get(key) ?? 0) + 1)
    }
    return [...counts.entries()].map(([label, value]) => ({ label: label.replace("_", " "), value }))
  }, [backlog.doc])

  const trend = useMemo(() => trendFrom(backlog.doc?.data.records ?? []), [backlog.doc])

  const activity = useMemo(() => {
    const m = overview.doc?.data.metrics ?? []
    const pick = (k: string) => m.find((x) => x.key === k)
    return [
      { label: "completions", key: "observed_done", color: "var(--fm-ok)" },
      { label: "blocks cleared", key: "observed_resolved", color: "var(--fm-info)" },
      { label: "decisions", key: "observed_needs_decision", color: "var(--fm-warn)" },
      { label: "blocks", key: "observed_blocked", color: "var(--fm-serious)" },
      { label: "failures", key: "observed_failed", color: "var(--fm-critical)" },
    ].map((row) => {
      const metric = pick(row.key)
      const value = typeof metric?.value === "number" ? metric.value : 0
      return { label: row.label, value, color: row.color }
    })
  }, [overview.doc])

  if (overview.error) return <ErrorPanel title="The overview could not be loaded" detail={overview.error} />
  if (overview.loading && !overview.doc) return <LoadingPanel rows={6} />
  const data = overview.doc!.data
  const alerts = data.alerts ?? []

  return (
    <div className="space-y-4">
      <div className="grid grid-cols-2 gap-2 sm:grid-cols-3 xl:grid-cols-6">
        {data.metrics.slice(0, 12).map((m) => (
          <KpiCard key={m.key} metric={m}
            alarming={ALARMING.has(m.key) && typeof m.value === "number" && m.value > 0}
            onSelect={setSelected} />
        ))}
      </div>

      <div className="grid items-start gap-3 xl:grid-cols-3">
        <Card className="gap-2 p-3">
          <SectionTitle aside={`${health.reduce((n, h) => n + h.value, 0)} workers`}>Fleet health</SectionTitle>
          {tasks.error
            ? <ErrorPanel title="Workers could not be read" detail={tasks.error} />
            : tasks.loading && !tasks.doc
              ? <LoadingPanel rows={3} />
              : <CompositionChart data={health} empty="No worker is running in this home." />}
        </Card>

        <Card className="gap-2 p-3 xl:col-span-2">
          <SectionTitle aside="from recorded backlog dates only">Work started and completed</SectionTitle>
          {backlog.error
            ? <ErrorPanel title="Backlog could not be read" detail={backlog.error} />
            : backlog.loading && !backlog.doc
              ? <LoadingPanel rows={3} />
              : <ActivityTrendChart data={trend}
                  empty="Fewer than two dated backlog days are recorded, so no trend can be drawn from evidence." />}
        </Card>
      </div>

      <div className="grid items-start gap-3 xl:grid-cols-3">
        <Card className="gap-2 p-3 xl:col-span-2">
          <SectionTitle aside={`${alerts.length} needing attention`}>Alert center</SectionTitle>
          {alerts.length === 0 ? (
            <EmptyPanel>Nothing is asking for attention: monitoring is confirmed, no evidence gaps, no open call.</EmptyPanel>
          ) : (
            <ScrollArea className="max-h-[260px]">
              <ul className="divide-y divide-border">
                {alerts.map((a, i) => (
                  <li key={`${a.key}-${i}`} className="flex items-start gap-2.5 py-2">
                    <span className="mt-1"><Dot tone={severityTone(a.severity)} /></span>
                    <div className="min-w-0 flex-1">
                      <div className="flex items-center gap-2">
                        <ToneBadge tone={severityTone(a.severity)}>{a.severity}</ToneBadge>
                        <span className="truncate text-sm font-medium text-foreground">{a.title}</span>
                      </div>
                      {a.detail ? <p className="mt-0.5 line-clamp-2 text-xs text-muted-foreground">{a.detail}</p> : null}
                      {a.sources?.filter(Boolean).length
                        ? <Mono className="mt-0.5 block">{a.sources.filter(Boolean).join("  ")}</Mono> : null}
                    </div>
                  </li>
                ))}
              </ul>
            </ScrollArea>
          )}
        </Card>

        <div className="space-y-3">
          <Card className="gap-2 p-3">
            <SectionTitle aside="retained history">Validation activity</SectionTitle>
            <CountBarChart data={activity} empty="No readable status history in this home." />
          </Card>
          <Card className="gap-2 p-3">
            <SectionTitle>Work mix</SectionTitle>
            <CountBarChart data={workMix} empty="No backlog records." />
          </Card>
        </div>
      </div>

      <Card className="gap-2 p-3">
        <SectionTitle aside="click a worker for its timeline">Workers</SectionTitle>
        {tasks.doc?.data.tasks?.length ? (
          <ul className="divide-y divide-border">
            {tasks.doc.data.tasks.map((t) => (
              <li key={t.id}>
                <button type="button" onClick={() => onOpenTask(t.id)}
                  className="flex w-full items-center gap-3 py-2 text-left hover:bg-muted/40">
                  <Dot tone={stateTone(t.state)} />
                  <span className="min-w-0 flex-1">
                    <span className="block truncate font-mono text-xs text-foreground">{t.id}</span>
                    <span className="block truncate text-[11px] text-muted-foreground">
                      {[t.backlog?.title, t.harness && `${t.harness}/${t.model ?? "—"}`, t.backend, t.endpoint?.target]
                        .filter(Boolean).join(" · ")}
                    </span>
                  </span>
                  {t.open_decisions?.length
                    ? <ToneBadge tone="critical">{t.open_decisions.length} call</ToneBadge> : null}
                  <ToneBadge tone={stateTone(t.state)}>{t.state ?? "unknown"}</ToneBadge>
                </button>
              </li>
            ))}
          </ul>
        ) : <EmptyPanel>No worker is running in this home.</EmptyPanel>}
      </Card>

      <div className="grid items-start gap-3 xl:grid-cols-2">
        <Card className="gap-2 p-3">
          <SectionTitle aside="recorded locally — no live check">Delivery status</SectionTitle>
          {delivery.error ? <ErrorPanel title="Delivery could not be read" detail={delivery.error} />
            : delivery.loading && !delivery.doc ? <LoadingPanel rows={2} />
            : (delivery.doc?.data.records.length ?? 0) === 0
              ? <EmptyPanel>No pull request is recorded in this home.</EmptyPanel>
              : (
                <ul className="divide-y divide-border">
                  {delivery.doc!.data.records.map((d, i) => (
                    <li key={i} className="flex items-start gap-3 py-2">
                      <div className="min-w-0 flex-1">
                        <p className="truncate font-mono text-xs">{dash(d.task_id)}</p>
                        {d.available === false
                          ? <Unavailable reason={d.reason} />
                          : <a href={d.url} target="_blank" rel="noreferrer noopener"
                              className="block truncate font-mono text-[11px] text-fm-info hover:underline">{d.url}</a>}
                      </div>
                      <ToneBadge tone="info">{dash(d.source)}</ToneBadge>
                    </li>
                  ))}
                </ul>
              )}
        </Card>

        <Card className="gap-2 p-3">
          <SectionTitle aside={`${reports.doc?.data.total ?? 0} indexed`}>Reports</SectionTitle>
          <Input value={reportQuery} onChange={(e) => setReportQuery(e.target.value)}
            placeholder="Search reports…" className="h-8 text-xs" aria-label="Search reports" />
          {reports.error ? <ErrorPanel title="Reports could not be read" detail={reports.error} />
            : reports.loading && !reports.doc ? <LoadingPanel rows={2} />
            : (() => {
              const rows = (reports.doc?.data.reports ?? []).filter((x) =>
                !reportQuery.trim() || `${x.id} ${x.path}`.toLowerCase().includes(reportQuery.trim().toLowerCase()))
              if (!rows.length) return <EmptyPanel>{reportQuery ? "No report matches." : "No report has been written."}</EmptyPanel>
              return (
                <ScrollArea className="max-h-[190px]">
                  <ul className="divide-y divide-border">
                    {rows.map((x) => (
                      <li key={x.id}>
                        <button type="button" disabled={!x.readable} onClick={() => onOpenReport(x.id)}
                          className="flex w-full items-start gap-2 py-1.5 text-left hover:bg-muted/40 disabled:opacity-60">
                          <span className="min-w-0 flex-1">
                            <span className="block truncate font-mono text-xs">{x.id}</span>
                            {x.readable
                              ? <Mono>{x.bytes} bytes{x.modified ? ` · ${x.modified}` : ""}</Mono>
                              : <Unavailable reason={x.reason} />}
                          </span>
                          {x.truncated ? <ToneBadge tone="warn">truncated</ToneBadge> : null}
                        </button>
                      </li>
                    ))}
                  </ul>
                </ScrollArea>
              )
            })()}
        </Card>
      </div>

      {selected ? (
        <MetricDetail metric={selected} onClose={() => setSelected(null)} />
      ) : null}
    </div>
  )
}

function MetricDetail({ metric, onClose }: { metric: Metric; onClose: () => void }) {
  return (
    <div className="fixed inset-0 z-50 grid place-items-center bg-background/80 p-4"
      role="dialog" aria-modal="true" aria-label={metric.label}
      onClick={(e) => { if (e.target === e.currentTarget) onClose() }}>
      <Card className="w-full max-w-lg gap-3 p-4">
        <div className="flex items-start justify-between gap-3">
          <div>
            <h3 className="text-sm font-semibold text-foreground">{metric.label}</h3>
            <Mono>{metric.key}</Mono>
          </div>
          <button type="button" onClick={onClose}
            className="rounded border border-border px-2 py-1 text-xs text-muted-foreground hover:text-foreground">
            Close <kbd className="ml-1 text-[10px]">esc</kbd>
          </button>
        </div>
        <dl className="grid grid-cols-[110px_1fr] gap-x-3 gap-y-1.5 text-xs">
          <dt className="text-muted-foreground">value</dt>
          <dd className="fm-num">{metric.available ? String(metric.value) : "unavailable"}</dd>
          <dt className="text-muted-foreground">kind</dt>
          <dd>{metric.kind === "retained_history" ? "derived from already-retained history" : "point-in-time read"}</dd>
          {metric.reason ? (<><dt className="text-muted-foreground">why unavailable</dt><dd className="text-fm-warn">{metric.reason}</dd></>) : null}
          {metric.detail ? (<><dt className="text-muted-foreground">note</dt><dd>{metric.detail}</dd></>) : null}
          <dt className="text-muted-foreground">sources</dt>
          <dd><Mono>{metric.sources.filter(Boolean).join("\n") || "—"}</Mono></dd>
        </dl>
        <p className="text-[11px] text-muted-foreground">
          Read from the records above. Nothing is estimated, and anything this home cannot
          support is reported unavailable with its reason.
        </p>
      </Card>
    </div>
  )
}

export { ago }
