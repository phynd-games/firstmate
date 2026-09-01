import type { ReactNode } from "react"
import {
  Activity, AlertCircle, Boxes, FileText, GitPullRequest, LayoutDashboard,
  ListChecks, Radar, Server, Menu,
} from "lucide-react"
import { Dot } from "@/components/primitives"
import { cn } from "@/lib/utils"
import type { LinkState } from "@/lib/api"
import type { Tone } from "@/lib/format"

export const NAV = [
  { key: "overview", label: "Overview", icon: LayoutDashboard },
  { key: "workers", label: "Workers", icon: Server },
  { key: "queue", label: "Queue", icon: ListChecks },
  { key: "backlog", label: "Backlog", icon: Boxes },
  { key: "delivery", label: "Delivery", icon: GitPullRequest },
  { key: "supervision", label: "Supervision", icon: Radar },
  { key: "reports", label: "Reports", icon: FileText },
  { key: "usage", label: "Usage", icon: Activity },
  { key: "sources", label: "Sources", icon: AlertCircle },
] as const

export type NavKey = (typeof NAV)[number]["key"]

const linkTone: Record<LinkState, Tone> = {
  live: "ok", "live-dev": "ok", connecting: "warn", reconnecting: "warn", offline: "critical",
}

export function Shell({
  route, onRoute, link, home, collectedAt, ageLabel, mobileOpen, onMobileToggle, children,
}: {
  route: NavKey
  onRoute: (k: NavKey) => void
  link: LinkState
  home: string | null
  collectedAt: string | null
  ageLabel: string
  mobileOpen: boolean
  onMobileToggle: () => void
  children: ReactNode
}) {
  return (
    <div className="flex min-h-screen bg-background text-foreground">
      {/* Compact sidebar: icon rail that widens on large screens, and a
          slide-over on small ones. Navigation never costs vertical space. */}
      <nav
        aria-label="Sections"
        className={cn(
          "fixed inset-y-0 left-0 z-40 flex w-56 shrink-0 flex-col border-r border-border bg-card transition-transform lg:static lg:w-14 lg:translate-x-0 xl:w-56",
          mobileOpen ? "translate-x-0" : "-translate-x-full",
        )}
      >
        <div className="flex h-12 items-center gap-2 border-b border-border px-3">
          <span className="grid size-6 shrink-0 place-items-center rounded bg-fm-info/15 text-fm-info">
            <Radar className="size-3.5" />
          </span>
          <span className="truncate text-[13px] font-semibold tracking-tight lg:hidden xl:inline">
            firstmate
          </span>
        </div>
        <ul className="flex-1 space-y-0.5 p-2">
          {NAV.map(({ key, label, icon: Icon }) => (
            <li key={key}>
              <button
                type="button"
                onClick={() => onRoute(key)}
                aria-current={route === key ? "page" : undefined}
                title={label}
                className={cn(
                  "flex w-full items-center gap-2.5 rounded px-2 py-1.5 text-[13px] transition-colors lg:justify-center xl:justify-start",
                  route === key
                    ? "bg-fm-info/10 text-fm-info"
                    : "text-muted-foreground hover:bg-muted/60 hover:text-foreground",
                )}
              >
                <Icon className="size-4 shrink-0" />
                <span className="truncate lg:hidden xl:inline">{label}</span>
              </button>
            </li>
          ))}
        </ul>
        <div className="border-t border-border p-3 text-[10px] text-muted-foreground lg:hidden xl:block">
          <p className="font-medium uppercase tracking-[0.12em]">read-only</p>
          <p className="mt-0.5 leading-snug">Firstmate remains the only control interface.</p>
        </div>
      </nav>

      {mobileOpen ? (
        <button type="button" aria-label="Close navigation" onClick={onMobileToggle}
          className="fixed inset-0 z-30 bg-background/70 lg:hidden" />
      ) : null}

      <div className="flex min-w-0 flex-1 flex-col">
        <header className="sticky top-0 z-20 flex h-12 items-center gap-3 border-b border-border bg-card/95 px-3 backdrop-blur">
          <button type="button" onClick={onMobileToggle} aria-label="Open navigation"
            className="rounded p-1 text-muted-foreground hover:text-foreground lg:hidden">
            <Menu className="size-4" />
          </button>
          <span className="text-[13px] font-semibold tracking-tight">Control plane</span>
          <span className="hidden truncate font-mono text-[11px] text-muted-foreground sm:inline">{home ?? "—"}</span>
          <span className="ml-auto flex items-center gap-3">
            <span className="hidden font-mono text-[11px] text-muted-foreground md:inline">
              read {collectedAt ?? "—"} {ageLabel ? `(${ageLabel})` : ""}
            </span>
            <span className="flex items-center gap-1.5 rounded border border-border px-1.5 py-0.5 text-[10px] uppercase tracking-wider text-muted-foreground">
              <Dot tone={linkTone[link]} />
              {link === "live-dev" ? "live · dev" : link}
            </span>
          </span>
        </header>
        <main className="min-w-0 flex-1 p-3">{children}</main>
      </div>
    </div>
  )
}
