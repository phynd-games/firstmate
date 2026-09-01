export type Metric = {
  key: string
  label: string
  value: number | boolean | string | null
  unit: string | null
  kind: "point_in_time" | "retained_history" | string
  available: boolean
  reason: string | null
  detail: string | null
  sources: (string | null)[]
}

export type AlertRow = {
  severity: "critical" | "warning" | "info" | string
  key: string
  title: string
  detail: string
  sources: (string | null)[]
}

export type Supervision = {
  model: string
  healthy: boolean
  reason: string
  beacon_present: boolean
  beacon_age_seconds: number | null
  away_mode: boolean
  recovery_marker: boolean
  wakes: {
    records: WakeRow[]
    total: number
    shown: number
    truncated: number
    available: boolean
    reason: string | null
  }
}

export type WakeRow = {
  epoch: number | null
  seq: string | null
  kind: string | null
  key: string | null
  payload: string | null
  malformed: boolean
}

export type Overview = {
  metrics: Metric[]
  alerts: AlertRow[]
  counts: { workers: number; secondmates: number; reports: number; degraded: number }
  supervision: Supervision
}

export type TaskRow = {
  id: string
  kind: string
  state: string | null
  state_source: string | null
  state_detail: string | null
  freshness: string | null
  observed_at: string | null
  harness: string | null
  model: string | null
  effort: string | null
  backend: string | null
  mode: string | null
  yolo: string | null
  endpoint: { target?: string | null; exists?: boolean | null; agent_alive?: string | null; status?: string | null; available?: boolean; reason?: string | null } | null
  pr: { url?: string | null; source?: string | null; available?: boolean; reason?: string | null } | null
  open_decisions: { key?: string; verb?: string; summary?: string }[]
  backlog: BacklogRow | null
  event_count: number
  event_total: number
  event_readable: boolean
  sources: (string | null)[]
}

export type BacklogRow = {
  id: string | null
  state: string | null
  structured: boolean
  title: string | null
  raw: string | null
  repo: string | null
  kind: string | null
  since: string | null
  merged: string | null
  reported: string | null
  done: string | null
  completion: { verb: string | null; date: string | null } | null
  hold_kind: string | null
  hold_reason: string | null
  hold_until: string | null
  captain_actionable: boolean
  unresolved_blocker_ids: string[]
  pr_url: string | null
  report_path: string | null
  body_excerpt: string | null
}

export type ReportRow = {
  id: string
  path: string
  readable: boolean
  reason: string | null
  bytes: number
  truncated: boolean
  modified: string | null
}
