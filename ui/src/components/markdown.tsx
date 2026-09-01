import type { ReactNode } from "react"

/* A deliberately small Markdown subset rendered into React elements.
   dangerouslySetInnerHTML is never used: report bodies are worker output and may
   contain anything, so raw HTML stays visible as text. Only http(s) targets
   become links. */
const INLINE =
  /(`[^`\n]+`)|(\*\*[\s\S]+?\*\*)|(\[[^\]\n]+\]\((?:https?:\/\/)[^\s)]+\))|(\bhttps?:\/\/[^\s<>()[\]]+)|(\*[^*\n]+\*)/g

const isHttp = (u: string) => /^https?:\/\//.test(u)

function inline(text: string, base: string): ReactNode[] {
  const out: ReactNode[] = []
  let last = 0
  let i = 0
  let m: RegExpExecArray | null
  INLINE.lastIndex = 0
  while ((m = INLINE.exec(text)) !== null) {
    if (m.index > last) out.push(text.slice(last, m.index))
    const tok = m[0]
    const key = `${base}-${i++}`
    if (m[1]) out.push(<code key={key} className="rounded bg-muted px-1 py-0.5 font-mono text-[0.85em]">{tok.slice(1, -1)}</code>)
    else if (m[2]) out.push(<strong key={key} className="font-semibold text-foreground">{tok.slice(2, -2)}</strong>)
    else if (m[3]) {
      const cut = tok.lastIndexOf("](")
      const url = tok.slice(cut + 2, -1)
      out.push(isHttp(url)
        ? <a key={key} href={url} target="_blank" rel="noreferrer noopener" className="text-fm-info hover:underline">{tok.slice(1, cut)}</a>
        : tok)
    } else if (m[4]) {
      out.push(isHttp(tok)
        ? <a key={key} href={tok} target="_blank" rel="noreferrer noopener" className="break-all text-fm-info hover:underline">{tok}</a>
        : tok)
    } else out.push(<em key={key}>{tok.slice(1, -1)}</em>)
    last = m.index + tok.length
  }
  if (last < text.length) out.push(text.slice(last))
  return out
}

const splitRow = (line: string) => {
  let t = line.trim()
  if (t.startsWith("|")) t = t.slice(1)
  if (t.endsWith("|")) t = t.slice(0, -1)
  return t.split("|").map((c) => c.trim())
}

export function Markdown({ text }: { text: string }) {
  const lines = String(text ?? "").split(/\r?\n/)
  const nodes: ReactNode[] = []
  let i = 0
  let k = 0
  while (i < lines.length) {
    const line = lines[i]
    if (/^\s*```/.test(line)) {
      const body: string[] = []
      i += 1
      while (i < lines.length && !/^\s*```/.test(lines[i])) body.push(lines[i++])
      if (i < lines.length) i += 1
      nodes.push(
        <pre key={k++} className="overflow-x-auto rounded border border-border bg-muted/50 p-3 text-[11px]">
          <code>{body.join("\n")}</code>
        </pre>)
      continue
    }
    if (/^\s*$/.test(line)) { i += 1; continue }
    if (/^\s*(-{3,}|\*{3,}|_{3,})\s*$/.test(line)) { nodes.push(<hr key={k++} className="border-border" />); i += 1; continue }
    const h = /^\s*(#{1,6})\s+(.*)$/.exec(line)
    if (h) {
      const size = ["text-base", "text-sm", "text-sm", "text-xs"][Math.min(h[1].length, 4) - 1]
      nodes.push(<p key={k++} className={`mt-3 font-semibold text-foreground ${size}`}>{inline(h[2].trim(), `h${k}`)}</p>)
      i += 1
      continue
    }
    if (/^\s*\|/.test(line) && i + 1 < lines.length
      && /^\s*\|?[\s:|-]*-[\s:|-]*$/.test(lines[i + 1]) && lines[i + 1].includes("|")) {
      const head = splitRow(line)
      i += 2
      const body: string[][] = []
      while (i < lines.length && /^\s*\|/.test(lines[i])) body.push(splitRow(lines[i++]))
      nodes.push(
        <div key={k++} className="overflow-x-auto">
          <table className="w-full border-collapse text-[11px]">
            <thead><tr>{head.map((c, n) => (
              <th key={n} className="border border-border bg-muted/50 px-2 py-1 text-left font-medium">{inline(c, `th${k}${n}`)}</th>
            ))}</tr></thead>
            <tbody>{body.map((row, rn) => (
              <tr key={rn}>{row.map((c, cn) => (
                <td key={cn} className="border border-border px-2 py-1 align-top">{inline(c, `td${k}${rn}${cn}`)}</td>
              ))}</tr>
            ))}</tbody>
          </table>
        </div>)
      continue
    }
    if (/^\s*>\s?/.test(line)) {
      const q: string[] = []
      while (i < lines.length && /^\s*>\s?/.test(lines[i])) q.push(lines[i++].replace(/^\s*>\s?/, ""))
      nodes.push(<blockquote key={k++} className="border-l-2 border-border pl-3 text-muted-foreground">{inline(q.join(" "), `q${k}`)}</blockquote>)
      continue
    }
    const bullet = /^\s*[-*+]\s+(.*)$/.exec(line)
    const ordered = /^\s*\d+[.)]\s+(.*)$/.exec(line)
    if (bullet || ordered) {
      const re = bullet ? /^\s*[-*+]\s+(.*)$/ : /^\s*\d+[.)]\s+(.*)$/
      const items: string[] = []
      while (i < lines.length) {
        const item = re.exec(lines[i])
        if (!item) break
        items.push(item[1]); i += 1
      }
      const List = bullet ? "ul" : "ol"
      nodes.push(
        <List key={k++} className={`ml-4 list-outside space-y-0.5 ${bullet ? "list-disc" : "list-decimal"}`}>
          {items.map((t, n) => <li key={n}>{inline(t, `li${k}${n}`)}</li>)}
        </List>)
      continue
    }
    const para: string[] = []
    while (i < lines.length && !/^\s*$/.test(lines[i]) && !/^\s*#{1,6}\s/.test(lines[i])
      && !/^\s*```/.test(lines[i]) && !/^\s*[-*+]\s/.test(lines[i])
      && !/^\s*\d+[.)]\s/.test(lines[i]) && !/^\s*>/.test(lines[i]) && !/^\s*\|/.test(lines[i])) {
      para.push(lines[i++])
    }
    if (para.length) nodes.push(<p key={k++}>{inline(para.join(" "), `p${k}`)}</p>)
    else i += 1
  }
  return <div className="space-y-2 text-xs leading-relaxed text-muted-foreground">{nodes}</div>
}
