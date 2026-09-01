import { AlertTriangle, HelpCircle } from "lucide-react"
import { Card } from "@/components/ui/card"
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip"
import { cn } from "@/lib/utils"
import type { Metric } from "@/lib/types"

const display = (m: Metric) => {
  if (typeof m.value === "boolean") return m.value ? "yes" : "no"
  if (m.value === null || m.value === undefined) return "—"
  return String(m.value)
}

/* A KPI states what it is AND whether it can be known. Unavailable is a
   first-class rendering with its reason on the face of the card, never a zero
   pretending to be a measurement. */
export function KpiCard({ metric, alarming, onSelect }: {
  metric: Metric
  alarming?: boolean
  onSelect?: (m: Metric) => void
}) {
  const na = !metric.available
  return (
    <Card
      onClick={onSelect ? () => onSelect(metric) : undefined}
      className={cn(
        "gap-0 rounded-md border p-2.5 transition-colors",
        onSelect && "cursor-pointer hover:border-ring/60",
        na && "border-dashed bg-muted/30",
        alarming && !na && "border-fm-critical/50 bg-fm-critical/5",
      )}
    >
      <div className="flex items-start justify-between gap-2">
        <span className="text-[10px] font-semibold uppercase tracking-[0.12em] text-muted-foreground">
          {metric.label}
        </span>
        {na ? (
          <Tooltip>
            <TooltipTrigger className="cursor-help" aria-label="why this is unavailable">
              <AlertTriangle className="size-3.5 shrink-0 text-fm-warn" />
            </TooltipTrigger>
            <TooltipContent className="max-w-xs text-xs">{metric.reason ?? "no reason recorded"}</TooltipContent>
          </Tooltip>
        ) : metric.detail ? (
          <Tooltip>
            <TooltipTrigger className="cursor-help" aria-label="metric detail">
              <HelpCircle className="size-3.5 shrink-0 text-muted-foreground/70" />
            </TooltipTrigger>
            <TooltipContent className="max-w-xs text-xs">{metric.detail}</TooltipContent>
          </Tooltip>
        ) : null}
      </div>
      <div className={cn(
        "fm-num mt-1 font-semibold tabular-nums",
        na ? "text-xs text-fm-warn" : alarming ? "text-xl text-fm-critical" : "text-xl text-foreground",
      )}>
        {na ? "unavailable" : display(metric)}
        {!na && metric.unit ? (
          <span className="ml-1 text-[11px] font-normal text-muted-foreground">{metric.unit}</span>
        ) : null}
      </div>
      <div className="mt-0.5 text-[10px] text-muted-foreground/80">
        {na ? "why it cannot be measured" : metric.kind === "retained_history" ? "retained history" : "point in time"}
      </div>
    </Card>
  )
}
