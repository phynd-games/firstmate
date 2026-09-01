import { EmptyPanel, ErrorPanel, LoadingPanel, Unavailable } from "@/components/primitives"
import { useResource } from "@/lib/use-resource"
import { Markdown } from "@/components/markdown"
import type { ReportRow } from "@/lib/types"

export function ReportDetail({ id, generation }: { id: string; generation: number }) {
  const r = useResource<{ report: ReportRow & { body: string } }>(`reports/${encodeURIComponent(id)}`, generation)
  if (r.error) return <ErrorPanel title="This report could not be loaded" detail={r.error} />
  if (r.loading && !r.doc) return <LoadingPanel rows={6} />
  const report = r.doc?.data.report
  if (!report) return <EmptyPanel>No record returned for this report.</EmptyPanel>
  if (!report.readable) return <EmptyPanel><Unavailable reason={report.reason} /></EmptyPanel>
  return (
    <div className="space-y-3">
      {report.truncated ? (
        <p className="rounded border border-fm-warn/40 bg-fm-warn/10 p-2 text-xs text-fm-warn">
          Shown truncated — this report is {report.bytes} bytes and only the leading part was read.
        </p>
      ) : null}
      <Markdown text={report.body} />
    </div>
  )
}
