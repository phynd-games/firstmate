export const dash = (v: unknown) =>
  v === null || v === undefined || v === "" ? "—" : String(v)

export function ago(seconds: number | null | undefined): string {
  if (typeof seconds !== "number" || !isFinite(seconds)) return ""
  const s = Math.max(0, Math.round(seconds))
  if (s < 90) return `${s}s ago`
  if (s < 5400) return `${Math.round(s / 60)}m ago`
  if (s < 172800) return `${Math.round(s / 3600)}h ago`
  return `${Math.round(s / 86400)}d ago`
}

export type Tone = "ok" | "warn" | "serious" | "critical" | "info" | "idle"

export const stateTone = (s: unknown): Tone => {
  switch (String(s ?? "").toLowerCase()) {
    case "done": case "passed": case "checks-passed": case "landed": return "ok"
    case "failed": case "cancelled": case "dead": case "missing": return "critical"
    case "blocked": case "needs-decision": return "serious"
    case "idle": case "waiting": return "info"
    case "paused": case "parked": return "warn"
    case "working": case "running": return "info"
    default: return "idle"
  }
}

export const severityTone = (s: unknown): Tone =>
  s === "critical" ? "critical" : s === "warning" ? "warn" : "info"

export const toneClass: Record<Tone, string> = {
  ok: "text-fm-ok border-fm-ok/40 bg-fm-ok/10",
  warn: "text-fm-warn border-fm-warn/40 bg-fm-warn/10",
  serious: "text-fm-serious border-fm-serious/40 bg-fm-serious/10",
  critical: "text-fm-critical border-fm-critical/40 bg-fm-critical/10",
  info: "text-fm-info border-fm-info/40 bg-fm-info/10",
  idle: "text-fm-idle border-fm-idle/40 bg-fm-idle/10",
}

export const CATEGORICAL = [
  "var(--fm-cat-1)", "var(--fm-cat-2)", "var(--fm-cat-3)",
  "var(--fm-cat-4)", "var(--fm-cat-5)",
] as const
