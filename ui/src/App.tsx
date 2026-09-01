import { useCallback, useEffect, useState } from "react"
import { Toaster } from "@/components/ui/sonner"
import { TooltipProvider } from "@/components/ui/tooltip"
import { Shell, type NavKey, NAV } from "@/components/shell"
import { SideDrawer } from "@/components/drawer"
import { OverviewView } from "@/views/overview"
import { TaskDetail } from "@/views/task-detail"
import { ReportDetail } from "@/views/report-detail"
import {
  BacklogView, DeliveryView, QueueView, ReportsView, SourcesView, SupervisionView, UsageView, WorkersView,
} from "@/views/rest"
import { subscribe, type LinkState } from "@/lib/api"
import { ago } from "@/lib/format"
import { useResource } from "@/lib/use-resource"
import type { Overview } from "@/lib/types"

type Drill = { kind: "task" | "report"; id: string } | null

const routeFromHash = (): NavKey => {
  const h = (window.location.hash || "").replace(/^#\/?/, "")
  return (NAV.some((n) => n.key === h) ? h : "overview") as NavKey
}

export default function App() {
  const [route, setRoute] = useState<NavKey>(routeFromHash)
  const [generation, setGeneration] = useState(0)
  const [link, setLink] = useState<LinkState>("connecting")
  const [drill, setDrill] = useState<Drill>(null)
  const [mobileOpen, setMobileOpen] = useState(false)

  // One cheap read drives the header's provenance line for every view.
  const head = useResource<Overview>("overview", generation)

  useEffect(() => {
    const onHash = () => setRoute(routeFromHash())
    window.addEventListener("hashchange", onHash)
    return () => window.removeEventListener("hashchange", onHash)
  }, [])

  useEffect(() => subscribe(() => setGeneration((g) => g + 1), setLink), [])

  const go = useCallback((k: NavKey) => {
    window.location.hash = `#/${k}`
    setRoute(k)
    setMobileOpen(false)
  }, [])

  const openTask = useCallback((id: string) => setDrill({ kind: "task", id }), [])
  const openReport = useCallback((id: string) => setDrill({ kind: "report", id }), [])

  return (
    <TooltipProvider>
      <Shell
        route={route}
        onRoute={go}
        link={link}
        home={head.doc?.home ?? null}
        collectedAt={head.doc?.collected_at ?? null}
        ageLabel={ago(head.doc?.age_seconds ?? null)}
        mobileOpen={mobileOpen}
        onMobileToggle={() => setMobileOpen((v) => !v)}
      >
        {route === "overview" ? <OverviewView generation={generation} onOpenTask={openTask} onOpenReport={openReport} /> : null}
        {route === "workers" ? <WorkersView generation={generation} onOpenTask={openTask} /> : null}
        {route === "queue" ? <QueueView generation={generation} /> : null}
        {route === "backlog" ? <BacklogView generation={generation} /> : null}
        {route === "delivery" ? <DeliveryView generation={generation} /> : null}
        {route === "supervision" ? <SupervisionView generation={generation} /> : null}
        {route === "reports" ? <ReportsView generation={generation} onOpen={openReport} /> : null}
        {route === "usage" ? <UsageView generation={generation} /> : null}
        {route === "sources" ? <SourcesView generation={generation} /> : null}
      </Shell>

      <SideDrawer
        open={drill !== null}
        onOpenChange={(v) => { if (!v) setDrill(null) }}
        title={drill?.id ?? ""}
        subtitle={drill?.kind === "task" ? "worker drill-down" : "report"}
      >
        {drill?.kind === "task" ? (
          <TaskDetail id={drill.id} generation={generation} onOpenReport={openReport} />
        ) : drill?.kind === "report" ? (
          <ReportDetail id={drill.id} generation={generation} />
        ) : null}
      </SideDrawer>
      <Toaster />
    </TooltipProvider>
  )
}
