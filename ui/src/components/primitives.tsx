import { AlertTriangle, FileWarning } from "lucide-react"
import type { ReactNode } from "react"
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert"
import { Skeleton } from "@/components/ui/skeleton"
import { cn } from "@/lib/utils"
import { type Tone, toneClass } from "@/lib/format"

export function ToneBadge({ tone, children }: { tone: Tone; children: ReactNode }) {
  return (
    <span className={cn(
      "inline-flex items-center gap-1.5 rounded border px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wider",
      toneClass[tone],
    )}>
      {children}
    </span>
  )
}

export function Dot({ tone }: { tone: Tone }) {
  const fill: Record<Tone, string> = {
    ok: "bg-fm-ok", warn: "bg-fm-warn", serious: "bg-fm-serious",
    critical: "bg-fm-critical", info: "bg-fm-info", idle: "bg-fm-idle",
  }
  return <span className={cn("size-1.5 shrink-0 rounded-full", fill[tone])} aria-hidden />
}

export function SectionTitle({ children, aside }: { children: ReactNode; aside?: ReactNode }) {
  return (
    <div className="flex items-baseline justify-between gap-3">
      <h2 className="text-[11px] font-semibold uppercase tracking-[0.14em] text-muted-foreground">
        {children}
      </h2>
      {aside ? <div className="text-[11px] text-muted-foreground">{aside}</div> : null}
    </div>
  )
}

/* Loading NEVER hangs on a bare string: it shows the shape of what is coming. */
export function LoadingPanel({ rows = 4 }: { rows?: number }) {
  return (
    <div className="space-y-2 p-4" role="status" aria-label="Loading evidence">
      {Array.from({ length: rows }).map((_, i) => (
        <Skeleton key={i} className="h-8 w-full" />
      ))}
    </div>
  )
}

export function ErrorPanel({ title, detail }: { title: string; detail?: string | null }) {
  return (
    <Alert variant="destructive" className="border-fm-critical/40 bg-fm-critical/10">
      <AlertTriangle className="size-4" />
      <AlertTitle>{title}</AlertTitle>
      {detail ? <AlertDescription className="break-words">{detail}</AlertDescription> : null}
    </Alert>
  )
}

/* An empty state says WHY it is empty. "Nothing here" and "we could not look"
   are different facts and must never render the same. */
export function EmptyPanel({ children }: { children: ReactNode }) {
  return (
    <div className="flex items-center gap-2 p-4 text-sm text-muted-foreground">
      <FileWarning className="size-4 shrink-0" />
      <span>{children}</span>
    </div>
  )
}

export function Unavailable({ reason }: { reason?: string | null }) {
  return (
    <span className="inline-flex items-center gap-1.5 text-xs text-fm-warn">
      <AlertTriangle className="size-3" />
      {reason?.trim() ? reason : "unavailable — no reason recorded"}
    </span>
  )
}

export function Mono({ children, className }: { children: ReactNode; className?: string }) {
  return <span className={cn("font-mono text-[11px] break-all text-muted-foreground", className)}>{children}</span>
}
