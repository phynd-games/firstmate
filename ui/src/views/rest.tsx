import { useState } from "react"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table"
import { Dot, EmptyPanel, ErrorPanel, LoadingPanel, Mono, SectionTitle, ToneBadge, Unavailable } from "@/components/primitives"
import { useResource } from "@/lib/use-resource"
import { ago, dash, severityTone, stateTone } from "@/lib/format"
import type { BacklogRow, ReportRow, Supervision, TaskRow, WakeRow } from "@/lib/types"

function Panel({ title, aside, children }: { title: string; aside?: string; children: React.ReactNode }) {
  return (
    <Card className="gap-2 p-3">
      <SectionTitle aside={aside}>{title}</SectionTitle>
      {children}
    </Card>
  )
}

/* Shared guard so every view resolves: data, or a concrete error, never a
   perpetual loading surface. */
function Guarded<T>({ r, label, children }: {
  r: { doc: { data: T } | null; error: string | null; loading: boolean }
  label: string
  children: (d: T) => React.ReactNode
}) {
  if (r.error) return <ErrorPanel title={`${label} could not be loaded`} detail={r.error} />
  if (r.loading && !r.doc) return <LoadingPanel />
  if (!r.doc) return <EmptyPanel>{label} returned nothing.</EmptyPanel>
  return <>{children(r.doc.data)}</>
}

export function WorkersView({ generation, onOpenTask }: { generation: number; onOpenTask: (id: string) => void }) {
  const r = useResource<{ tasks: TaskRow[] }>("tasks", generation)
  const [q, setQ] = useState("")
  return (
    <Panel title="Workers and second mates" aside="reconciled at read time">
      <Input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Filter workers…"
        className="h-8 max-w-xs text-xs" aria-label="Filter workers" />
      <Guarded r={r} label="Workers">{(d) => {
        const rows = d.tasks.filter((t) =>
          !q.trim() || `${t.id} ${t.state} ${t.harness} ${t.model} ${t.backend} ${t.backlog?.title ?? ""}`
            .toLowerCase().includes(q.trim().toLowerCase()))
        if (!rows.length) return <EmptyPanel>{q ? "No worker matches that filter." : "No worker is running in this home."}</EmptyPanel>
        return (
          <div className="overflow-x-auto">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Worker</TableHead><TableHead>State</TableHead>
                  <TableHead>Runtime</TableHead><TableHead>Endpoint</TableHead>
                  <TableHead>Delivery</TableHead><TableHead className="text-right">Events</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {rows.map((t) => (
                  <TableRow key={t.id} onClick={() => onOpenTask(t.id)} className="cursor-pointer">
                    <TableCell className="max-w-[280px]">
                      <span className="block truncate font-mono text-xs">{t.id}</span>
                      <span className="block truncate text-[11px] text-muted-foreground">{dash(t.backlog?.title)}</span>
                    </TableCell>
                    <TableCell>
                      <span className="flex items-center gap-1.5">
                        <Dot tone={stateTone(t.state)} />
                        <ToneBadge tone={stateTone(t.state)}>{dash(t.state)}</ToneBadge>
                      </span>
                      <span className="mt-0.5 block text-[10px] text-muted-foreground">{dash(t.state_detail)}</span>
                    </TableCell>
                    <TableCell className="text-xs">{dash(t.harness)} / {dash(t.model)}<br />
                      <span className="text-[10px] text-muted-foreground">{dash(t.effort)}</span></TableCell>
                    <TableCell className="text-xs">
                      {t.endpoint?.available === false
                        ? <Unavailable reason={t.endpoint.reason} />
                        : <><Mono>{dash(t.endpoint?.target)}</Mono><br />
                          <span className="text-[10px] text-muted-foreground">
                            {t.endpoint?.exists === true ? "present" : t.endpoint?.exists === false ? "absent" : "unknown"}
                          </span></>}
                    </TableCell>
                    <TableCell className="text-xs">{dash(t.mode)}<br />
                      <span className="text-[10px] text-muted-foreground">
                        {t.yolo === "on" ? "auto merge" : "captain merges"}</span></TableCell>
                    <TableCell className="fm-num text-right text-xs">
                      {t.event_readable ? `${t.event_count}/${t.event_total}` : <Unavailable reason="event history unavailable" />}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        )
      }}</Guarded>
    </Panel>
  )
}

export function QueueView({ generation }: { generation: number }) {
  const r = useResource<{ wakes: Supervision["wakes"]; holds: BacklogRow[]; decisions: { task_id: string; decision: { key?: string; verb?: string; summary?: string } }[] }>("queue", generation)
  return (
    <div className="space-y-3">
      <Guarded r={r} label="Queue">{(d) => (
        <>
          <Panel title="Open captain's calls" aside={`${d.decisions.length}`}>
            {d.decisions.length === 0 ? <EmptyPanel>Nothing is waiting on the captain.</EmptyPanel> : (
              <ul className="divide-y divide-border">
                {d.decisions.map((x, i) => (
                  <li key={i} className="py-2">
                    <div className="flex items-center gap-2">
                      <ToneBadge tone="critical">{dash(x.decision.verb ?? "open")}</ToneBadge>
                      <span className="font-mono text-[11px] text-muted-foreground">{dash(x.decision.key)}</span>
                    </div>
                    <p className="mt-0.5 text-sm">{dash(x.decision.summary)}</p>
                    <Mono>raised by {x.task_id}</Mono>
                  </li>
                ))}
              </ul>
            )}
          </Panel>
          <Panel title="Held work" aside={`${d.holds.length}`}>
            {d.holds.length === 0 ? <EmptyPanel>Nothing held.</EmptyPanel> : (
              <ul className="divide-y divide-border">
                {d.holds.map((h, i) => (
                  <li key={i} className="flex items-start gap-3 py-2">
                    <div className="min-w-0 flex-1">
                      <p className="truncate text-sm">{dash(h.title ?? h.raw)}</p>
                      <p className="text-[11px] text-muted-foreground">
                        {[h.repo, h.hold_reason, h.hold_until && `deferred to ${h.hold_until}`,
                          h.unresolved_blocker_ids?.length && `waiting on ${h.unresolved_blocker_ids.join(", ")}`]
                          .filter(Boolean).join(" · ")}
                      </p>
                    </div>
                    <ToneBadge tone={h.captain_actionable ? "critical" : "warn"}>
                      {h.captain_actionable ? "your call now" : "deferred"}
                    </ToneBadge>
                  </li>
                ))}
              </ul>
            )}
          </Panel>
          <Panel title="Unacknowledged notifications" aside={`${d.wakes?.total ?? 0}`}>
            {!d.wakes?.available ? <EmptyPanel><Unavailable reason={d.wakes?.reason} /></EmptyPanel>
              : d.wakes.records.length === 0 ? <EmptyPanel>{dash(d.wakes.reason ?? "Nothing queued.")}</EmptyPanel> : (
                <div className="overflow-x-auto">
                  <Table>
                    <TableHeader><TableRow>
                      <TableHead>Queued</TableHead><TableHead>No.</TableHead>
                      <TableHead>Kind</TableHead><TableHead>About</TableHead><TableHead>Detail</TableHead>
                    </TableRow></TableHeader>
                    <TableBody>
                      {d.wakes.records.map((w: WakeRow, i: number) => (
                        <TableRow key={i}>
                          <TableCell className="fm-num text-xs">
                            {w.malformed ? "—" : new Date((w.epoch ?? 0) * 1000).toISOString().replace(/\.\d+Z$/, "Z")}
                          </TableCell>
                          <TableCell className="fm-num text-xs">{dash(w.seq)}</TableCell>
                          <TableCell>{w.malformed
                            ? <ToneBadge tone="critical">unreadable</ToneBadge>
                            : <ToneBadge tone={w.kind === "stale" ? "critical" : "info"}>{dash(w.kind)}</ToneBadge>}</TableCell>
                          <TableCell><Mono>{dash(w.key)}</Mono></TableCell>
                          <TableCell className="text-xs">{dash(w.payload)}</TableCell>
                        </TableRow>
                      ))}
                    </TableBody>
                  </Table>
                </div>
              )}
          </Panel>
        </>
      )}</Guarded>
    </div>
  )
}

export function BacklogView({ generation }: { generation: number }) {
  const r = useResource<{ records: BacklogRow[] }>("backlog", generation)
  const [q, setQ] = useState("")
  return (
    <Panel title="Backlog" aside="exactly as recorded">
      <Input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Search backlog…"
        className="h-8 max-w-xs text-xs" aria-label="Search backlog" />
      <Guarded r={r} label="Backlog">{(d) => {
        const rows = d.records.filter((x) =>
          !q.trim() || `${x.id} ${x.title} ${x.raw} ${x.repo} ${x.kind}`.toLowerCase().includes(q.trim().toLowerCase()))
        if (!rows.length) return <EmptyPanel>{q ? "No backlog row matches." : "No backlog records."}</EmptyPanel>
        return (
          <div className="space-y-3">
            {(["in_flight", "queued", "done"] as const).map((state) => {
              const group = rows.filter((x) => x.state === state)
              return (
                <div key={state}>
                  <p className="mb-1 text-[10px] font-semibold uppercase tracking-[0.14em] text-muted-foreground">
                    {state.replace("_", " ")} ({group.length})
                  </p>
                  {group.length === 0 ? <p className="text-xs text-muted-foreground">Nothing here.</p> : (
                    <ul className="divide-y divide-border rounded border border-border">
                      {group.map((x, i) => (
                        <li key={i} className="flex items-start gap-3 px-3 py-2">
                          <div className="min-w-0 flex-1">
                            <p className="truncate text-sm">{dash(x.title ?? x.raw)}</p>
                            <p className="text-[11px] text-muted-foreground">
                              {[x.repo, x.kind, x.since && `since ${x.since}`,
                                x.completion?.verb && `${x.completion.verb} ${dash(x.completion.date)}`]
                                .filter(Boolean).join(" · ")}
                            </p>
                          </div>
                          {!x.structured ? <ToneBadge tone="warn">free-form</ToneBadge> : null}
                          {x.pr_url ? <a href={x.pr_url} target="_blank" rel="noreferrer noopener"
                            className="text-xs text-fm-info hover:underline">PR</a> : null}
                        </li>
                      ))}
                    </ul>
                  )}
                </div>
              )
            })}
          </div>
        )
      }}</Guarded>
    </Panel>
  )
}

export function DeliveryView({ generation }: { generation: number }) {
  const r = useResource<{ records: { task_id: string; url: string; source: string; mode?: string; yolo?: string; merged?: string; available?: boolean; reason?: string }[]; note: string }>("delivery", generation)
  return (
    <Panel title="Delivery" aside="recorded locally — no live check">
      <Guarded r={r} label="Delivery">{(d) => (
        <>
          <p className="text-[11px] text-muted-foreground">{d.note}</p>
          {d.records.length === 0 ? <EmptyPanel>No pull request is recorded in this home.</EmptyPanel> : (
            <div className="overflow-x-auto">
              <Table>
                <TableHeader><TableRow>
                  <TableHead>Task</TableHead><TableHead>Pull request</TableHead>
                  <TableHead>Recorded from</TableHead><TableHead>Delivery</TableHead>
                </TableRow></TableHeader>
                <TableBody>
                  {d.records.map((x, i) => (
                    <TableRow key={i}>
                      <TableCell><Mono>{dash(x.task_id)}</Mono></TableCell>
                      <TableCell>{x.available === false
                        ? <Unavailable reason={x.reason} />
                        : <a href={x.url} target="_blank" rel="noreferrer noopener"
                            className="font-mono text-[11px] text-fm-info hover:underline">{x.url}</a>}</TableCell>
                      <TableCell className="text-xs">{dash(x.source)}</TableCell>
                      <TableCell className="text-xs">
                        {x.mode ? `${x.mode} — ${x.yolo === "on" ? "auto merge" : "captain merges"}` : dash(x.merged)}
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
          )}
        </>
      )}</Guarded>
    </Panel>
  )
}

export function SupervisionView({ generation }: { generation: number }) {
  const r = useResource<{ supervision: Supervision; degraded: { source: string; path: string; reason: string }[]; inventory: { valid?: boolean; reason?: string | null } | null }>("supervision", generation)
  return (
    <div className="space-y-3">
      <Guarded r={r} label="Supervision">{(d) => (
        <>
          <Panel title="Monitoring">
            <div className="flex flex-wrap items-center gap-2">
              <ToneBadge tone={d.supervision.healthy ? "ok" : "critical"}>
                {d.supervision.healthy ? "confirmed healthy" : "not confirmed"}
              </ToneBadge>
              <span className="text-xs text-muted-foreground">
                reason {dash(d.supervision.reason)} · model {dash(d.supervision.model)} · heartbeat{" "}
                {d.supervision.beacon_present ? ago(d.supervision.beacon_age_seconds) || "unknown age" : "never recorded"}
              </span>
              {d.supervision.away_mode ? <ToneBadge tone="info">away mode</ToneBadge> : null}
              {d.supervision.recovery_marker ? <ToneBadge tone="warn">recovering</ToneBadge> : null}
            </div>
          </Panel>
          {d.inventory?.valid === false
            ? <ErrorPanel title="Current-work inventory does not add up" detail={d.inventory.reason} /> : null}
          <Panel title="Evidence gaps" aside={`${d.degraded.length}`}>
            {d.degraded.length === 0 ? <EmptyPanel>Every recorded source was readable.</EmptyPanel> : (
              <ul className="divide-y divide-border">
                {d.degraded.map((x, i) => (
                  <li key={i} className="py-2">
                    <p className="text-sm">Not shown: {x.source}</p>
                    <p className="text-[11px] text-fm-warn">{x.reason}</p>
                    <Mono>{x.path}</Mono>
                  </li>
                ))}
              </ul>
            )}
          </Panel>
        </>
      )}</Guarded>
    </div>
  )
}

export function ReportsView({ generation, onOpen }: { generation: number; onOpen: (id: string) => void }) {
  const r = useResource<{ reports: ReportRow[]; total: number; truncated: number }>("reports", generation)
  const [q, setQ] = useState("")
  return (
    <Panel title="Reports and findings" aside="durable worker deliverables">
      <Input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Search reports…"
        className="h-8 max-w-xs text-xs" aria-label="Search reports" />
      <Guarded r={r} label="Reports">{(d) => {
        const rows = d.reports.filter((x) => !q.trim() || `${x.id} ${x.path}`.toLowerCase().includes(q.trim().toLowerCase()))
        if (!rows.length) return <EmptyPanel>{q ? "No report matches." : "No report has been written in this home."}</EmptyPanel>
        return (
          <>
            <ul className="divide-y divide-border">
              {rows.map((x) => (
                <li key={x.id}>
                  <button type="button" disabled={!x.readable} onClick={() => onOpen(x.id)}
                    className="flex w-full items-start gap-3 py-2 text-left hover:bg-muted/40 disabled:cursor-not-allowed disabled:opacity-60">
                    <div className="min-w-0 flex-1">
                      <p className="truncate font-mono text-xs">{x.id}</p>
                      <Mono>{x.path}</Mono>
                      <p className="text-[10px] text-muted-foreground">
                        {x.readable ? `${x.bytes} bytes${x.modified ? ` · modified ${x.modified}` : ""}` : null}
                      </p>
                      {!x.readable ? <Unavailable reason={x.reason} /> : null}
                    </div>
                    {x.truncated ? <ToneBadge tone="warn">truncated</ToneBadge> : null}
                  </button>
                </li>
              ))}
            </ul>
            {d.truncated > 0 ? (
              <p className="pt-2 text-[11px] text-fm-warn">
                {d.truncated} further report{d.truncated === 1 ? "" : "s"} were not indexed under this home's report cap,
                and are not addressable here.
              </p>
            ) : null}
          </>
        )
      }}</Guarded>
    </Panel>
  )
}

export function UsageView({ generation }: { generation: number }) {
  const r = useResource<{ usage: { agents: { task_id: string; harness: string; model: string; effort: string }[]; budget: { available: boolean; reason?: string | null; files?: { file: string; bytes: number; estimated_tokens: number; status: string }[]; total_estimated_tokens?: number; effective_budget_tokens?: number; status?: string } } }>("usage", generation)
  return (
    <div className="space-y-3">
      <Guarded r={r} label="Usage">{(d) => (
        <>
          <Panel title="No vendor usage meter exists locally">
            <p className="text-xs text-muted-foreground">
              Real token or cost consumption is not available on this machine, so it is reported
              unavailable rather than estimated. The figures below are this home's startup-memory
              budget estimate — a budget, not consumption.
            </p>
          </Panel>
          <Panel title="Dispatched runtimes" aside={`${d.usage.agents.length}`}>
            {d.usage.agents.length === 0 ? <EmptyPanel>No worker is running.</EmptyPanel> : (
              <Table>
                <TableHeader><TableRow>
                  <TableHead>Task</TableHead><TableHead>Runtime</TableHead>
                  <TableHead>Model</TableHead><TableHead>Effort</TableHead>
                </TableRow></TableHeader>
                <TableBody>
                  {d.usage.agents.map((a, i) => (
                    <TableRow key={i}>
                      <TableCell><Mono>{dash(a.task_id)}</Mono></TableCell>
                      <TableCell className="text-xs">{dash(a.harness)}</TableCell>
                      <TableCell><Mono>{dash(a.model)}</Mono></TableCell>
                      <TableCell className="text-xs">{dash(a.effort)}</TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            )}
          </Panel>
          <Panel title="Startup memory budget" aside="estimate, not a meter">
            {!d.usage.budget.available ? <EmptyPanel><Unavailable reason={d.usage.budget.reason} /></EmptyPanel> : (
              <>
                <Table>
                  <TableHeader><TableRow>
                    <TableHead>File</TableHead><TableHead className="text-right">Bytes</TableHead>
                    <TableHead className="text-right">Est. tokens</TableHead><TableHead>State</TableHead>
                  </TableRow></TableHeader>
                  <TableBody>
                    {(d.usage.budget.files ?? []).map((f, i) => (
                      <TableRow key={i}>
                        <TableCell><Mono>{f.file}</Mono></TableCell>
                        <TableCell className="fm-num text-right text-xs">{f.bytes}</TableCell>
                        <TableCell className="fm-num text-right text-xs">{f.estimated_tokens}</TableCell>
                        <TableCell className="text-xs">{f.status}</TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
                <p className="pt-2 text-xs">
                  <span className="fm-num font-semibold">{d.usage.budget.total_estimated_tokens}</span>
                  {" of "}<span className="fm-num">{d.usage.budget.effective_budget_tokens}</span> estimated tokens
                  {" — "}<span className="text-muted-foreground">{dash(d.usage.budget.status)}</span>
                </p>
              </>
            )}
          </Panel>
        </>
      )}</Guarded>
    </div>
  )
}

export function SourcesView({ generation }: { generation: number }) {
  const r = useResource<{ sources: { surface: string; path: string }[] }>("sources", generation)
  const [q, setQ] = useState("")
  return (
    <Panel title="Exact sources" aside="every path the server read">
      <Input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Search paths…"
        className="h-8 max-w-xs text-xs" aria-label="Search source paths" />
      <p className="text-[11px] text-muted-foreground">
        The browser never reads a filesystem path. The server read these, and every claim on this
        dashboard can be checked at its source.
      </p>
      <Guarded r={r} label="Sources">{(d) => {
        const rows = d.sources.filter((x) => !q.trim() || `${x.surface} ${x.path}`.toLowerCase().includes(q.trim().toLowerCase()))
        if (!rows.length) return <EmptyPanel>No source matches.</EmptyPanel>
        return (
          <div className="overflow-x-auto">
            <Table>
              <TableHeader><TableRow><TableHead>Surface</TableHead><TableHead>Path</TableHead></TableRow></TableHeader>
              <TableBody>
                {rows.map((x, i) => (
                  <TableRow key={i}>
                    <TableCell className="text-xs">{dash(x.surface)}</TableCell>
                    <TableCell><Mono>{dash(x.path)}</Mono></TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        )
      }}</Guarded>
    </Panel>
  )
}

export { severityTone }
