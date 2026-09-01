import { Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle } from "@/components/ui/sheet"
import { ScrollArea } from "@/components/ui/scroll-area"
import type { ReactNode } from "react"

/* Drill-down is a side drawer, so context stays on screen behind it. */
export function SideDrawer({ open, onOpenChange, title, subtitle, children }: {
  open: boolean
  onOpenChange: (v: boolean) => void
  title: string
  subtitle?: string | null
  children: ReactNode
}) {
  return (
    <Sheet open={open} onOpenChange={onOpenChange}>
      <SheetContent side="right" className="w-full gap-0 p-0 sm:max-w-xl">
        <SheetHeader className="border-b border-border px-4 py-3">
          <SheetTitle className="truncate font-mono text-sm">{title}</SheetTitle>
          {subtitle ? (
            <SheetDescription className="break-all font-mono text-[11px]">{subtitle}</SheetDescription>
          ) : null}
        </SheetHeader>
        <ScrollArea className="h-[calc(100vh-3.5rem)]">
          <div className="p-4">{children}</div>
        </ScrollArea>
      </SheetContent>
    </Sheet>
  )
}
