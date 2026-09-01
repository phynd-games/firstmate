import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";

export function processInstanceIdentity(pid: string): string {
  if (!/^[0-9]+$/.test(pid)) return "";
  const procRoot = process.env.FM_PROC_ROOT_OVERRIDE || "/proc";
  try {
    const statLine = readFileSync(`${procRoot}/${pid}/stat`, "utf8");
    const fields = statLine.slice(statLine.lastIndexOf(")") + 1).trim().split(/\s+/);
    const starttime = fields[19];
    if (!starttime || !/^\d+$/.test(starttime)) return "";
    const cmdline = readFileSync(`${procRoot}/${pid}/cmdline`);
    if (!cmdline.length) return "";
    const identityKey = process.platform === "linux" ? "linux-starttime" : "proc-starttime";
    return `${identityKey}=${starttime} cmdline-hex=${cmdline.toString("hex")}`;
  } catch {
  }
  const result = spawnSync("ps", ["-p", pid, "-o", "lstart=", "-o", "command="], {
    encoding: "utf8",
    env: { ...process.env, LC_ALL: "C" },
  });
  if (result.status !== 0) return "";
  return result.stdout.trim();
}
