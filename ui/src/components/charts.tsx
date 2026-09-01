import { Cell, Pie, PieChart, Area, AreaChart, Bar, BarChart, CartesianGrid, XAxis, YAxis } from "recharts"
import {
  ChartContainer, ChartLegend, ChartLegendContent, ChartTooltip, ChartTooltipContent,
  type ChartConfig,
} from "@/components/ui/chart"
import { EmptyPanel } from "@/components/primitives"

/* Every chart here is fed from authoritative local records only. Where the
   evidence cannot support a visual - most importantly anything needing a time
   series this home does not retain - the caller renders an explicit unavailable
   state instead of a chart, rather than inventing a shape. */

export type Slice = { name: string; value: number; color: string }

export function CompositionChart({ data, empty }: { data: Slice[]; empty: string }) {
  const total = data.reduce((n, d) => n + d.value, 0)
  if (!total) return <EmptyPanel>{empty}</EmptyPanel>
  const config: ChartConfig = Object.fromEntries(
    data.map((d) => [d.name, { label: d.name, color: d.color }]),
  )
  return (
    <ChartContainer config={config} className="mx-auto h-[188px] w-full">
      <PieChart>
        <ChartTooltip content={<ChartTooltipContent hideLabel />} />
        {/* 2px surface gap between segments keeps adjacent fills readable. */}
        <Pie data={data} dataKey="value" nameKey="name" innerRadius={42} outerRadius={68} paddingAngle={2} strokeWidth={2}>
          {data.map((d) => <Cell key={d.name} fill={d.color} stroke="var(--card)" />)}
        </Pie>
        <ChartLegend content={<ChartLegendContent nameKey="name" />} className="flex-wrap gap-x-3 gap-y-1 text-[11px]" />
      </PieChart>
    </ChartContainer>
  )
}

export type Bucket = { label: string; value: number; color?: string }

export function CountBarChart({ data, empty }: { data: Bucket[]; empty: string }) {
  if (!data.some((d) => d.value > 0)) return <EmptyPanel>{empty}</EmptyPanel>
  const config: ChartConfig = { value: { label: "count" } }
  return (
    <ChartContainer config={config} className="h-[188px] w-full">
      <BarChart data={data} layout="vertical" margin={{ left: 4, right: 16, top: 4, bottom: 4 }}>
        <CartesianGrid horizontal={false} stroke="var(--border)" strokeOpacity={0.4} />
        <XAxis type="number" allowDecimals={false} tickLine={false} axisLine={false}
          tick={{ fontSize: 10, fill: "var(--muted-foreground)" }} />
        <YAxis type="category" dataKey="label" width={116} tickLine={false} axisLine={false}
          tick={{ fontSize: 11, fill: "var(--muted-foreground)" }} />
        <ChartTooltip cursor={{ fill: "var(--muted)", opacity: 0.25 }} content={<ChartTooltipContent hideLabel />} />
        <Bar dataKey="value" radius={[0, 4, 4, 0]} barSize={12}>
          {data.map((d, i) => <Cell key={d.label} fill={d.color ?? `var(--fm-cat-${(i % 5) + 1})`} />)}
        </Bar>
      </BarChart>
    </ChartContainer>
  )
}

export type TrendPoint = { day: string; started: number; completed: number }

export function ActivityTrendChart({ data, empty }: { data: TrendPoint[]; empty: string }) {
  if (data.length < 2) return <EmptyPanel>{empty}</EmptyPanel>
  const config: ChartConfig = {
    started: { label: "Started", color: "var(--fm-cat-1)" },
    completed: { label: "Completed", color: "var(--fm-cat-2)" },
  }
  return (
    <ChartContainer config={config} className="h-[188px] w-full">
      <AreaChart data={data} margin={{ left: 4, right: 12, top: 8, bottom: 4 }}>
        <CartesianGrid vertical={false} stroke="var(--border)" strokeOpacity={0.4} />
        <XAxis dataKey="day" tickLine={false} axisLine={false} tickMargin={6}
          tick={{ fontSize: 10, fill: "var(--muted-foreground)" }} />
        <YAxis allowDecimals={false} width={26} tickLine={false} axisLine={false}
          tick={{ fontSize: 10, fill: "var(--muted-foreground)" }} />
        <ChartTooltip content={<ChartTooltipContent indicator="line" />} />
        <Area dataKey="started" type="linear" dot={{ r: 2.5 }} activeDot={{ r: 4 }} stroke="var(--fm-cat-1)" strokeWidth={2}
          fill="var(--fm-cat-1)" fillOpacity={0.16} />
        <Area dataKey="completed" type="linear" dot={{ r: 2.5 }} activeDot={{ r: 4 }} stroke="var(--fm-cat-2)" strokeWidth={2}
          fill="var(--fm-cat-2)" fillOpacity={0.16} />
        <ChartLegend content={<ChartLegendContent />} className="text-[11px]" />
      </AreaChart>
    </ChartContainer>
  )
}
