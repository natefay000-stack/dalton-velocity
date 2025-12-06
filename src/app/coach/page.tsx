"use client";

import { useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { supabase } from "@/lib/supabase/client";
import BottomNav from "@/components/BottomNav";
import { Bebas_Neue } from "next/font/google";
import { PROGRAM_START, PROGRAM_END } from "@/lib/program";

const bebas = Bebas_Neue({ subsets: ["latin"], weight: "400" });

type Profile = {
  id: string;
  display_name: string | null;
  grad_year: string | null;
};

type RawLog = {
  user_id: string;
  log_date: string;
  throwing_time: number | null;
  throwing_distance: number | null;
  flat_ground: boolean;
  bullpen: boolean;
  arm_feeling: number | null;
  notes: string | null;
};

type JoinedLog = {
  playerName: string;
  gradYear: string | null;
  logDate: string;
  throwingTime: number | null;
  throwingDistance: number | null;
  flatGround: boolean;
  bullpen: boolean;
  armFeeling: number | null;
  notes: string | null;
};

const COACH_PIN = process.env.NEXT_PUBLIC_COACH_PIN || "";

// Simple CSV escaping
function csvEscape(value: string | null | undefined): string {
  if (value === null || value === undefined) return "";
  const v = String(value);
  if (v.includes('"') || v.includes(",") || v.includes("\n")) {
    return `"${v.replace(/"/g, '""')}"`;
  }
  return v;
}

export default function CoachPage() {
  const router = useRouter();

  const [pinInput, setPinInput] = useState("");
  const [pinError, setPinError] = useState<string | null>(null);
  const [unlocked, setUnlocked] = useState(false);

  const [loading, setLoading] = useState(false);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [profiles, setProfiles] = useState<Profile[]>([]);
  const [logs, setLogs] = useState<RawLog[]>([]);

  // Check that user is logged in at all
  useEffect(() => {
    let cancelled = false;

    async function checkUser() {
      const {
        data: { user },
      } = await supabase.auth.getUser();

      if (!cancelled && !user) {
        router.replace("/login");
      }
    }

    checkUser();

    return () => {
      cancelled = true;
    };
  }, [router]);

  // When unlocked, load all data for export/coach view
  useEffect(() => {
    if (!unlocked) return;

    let cancelled = false;

    async function loadData() {
      setLoading(true);
      setLoadError(null);

      try {
        // Load profiles
        const { data: profileData, error: profileErr } = await supabase
          .from("profiles")
          .select("id, display_name, grad_year")
          .order("display_name", { ascending: true });

        if (profileErr) {
          console.error("Error loading profiles:", profileErr);
          throw new Error("COULD NOT LOAD PROFILES.");
        }

        // Load logs in program range
        const { data: logData, error: logErr } = await supabase
          .from("daily_logs")
          .select(
            "user_id, log_date, throwing_time, throwing_distance, flat_ground, bullpen, arm_feeling, notes"
          )
          .gte("log_date", PROGRAM_START)
          .lte("log_date", PROGRAM_END)
          .order("log_date", { ascending: true });

        if (logErr) {
          console.error("Error loading logs:", logErr);
          throw new Error("COULD NOT LOAD LOGS.");
        }

        if (!cancelled) {
          setProfiles((profileData || []) as Profile[]);
          setLogs((logData || []) as RawLog[]);
        }
      } catch (e: any) {
        if (!cancelled) {
          setLoadError(e.message || "COULD NOT LOAD COACH DATA.");
        }
      } finally {
        if (!cancelled) setLoading(false);
      }
    }

    loadData();

    return () => {
      cancelled = true;
    };
  }, [unlocked]);

  const profileById = useMemo(() => {
    const map: Record<string, Profile> = {};
    for (const p of profiles) {
      map[p.id] = p;
    }
    return map;
  }, [profiles]);

  const joinedLogs: JoinedLog[] = useMemo(() => {
    const rows: JoinedLog[] = logs.map((log) => {
      const p = profileById[log.user_id];
      const name = p?.display_name || "PLAYER";
      return {
        playerName: name,
        gradYear: p?.grad_year || null,
        logDate: log.log_date,
        throwingTime: log.throwing_time,
        throwingDistance: log.throwing_distance,
        flatGround: log.flat_ground,
        bullpen: log.bullpen,
        armFeeling: log.arm_feeling,
        notes: log.notes,
      };
    });

    // Sort by player name, then date
    rows.sort((a, b) => {
      const n = a.playerName.localeCompare(b.playerName);
      if (n !== 0) return n;
      return a.logDate.localeCompare(b.logDate);
    });

    return rows;
  }, [logs, profileById]);

  const totalPlayers = useMemo(() => {
    const set = new Set<string>();
    for (const row of joinedLogs) {
      set.add(`${row.playerName}||${row.gradYear || ""}`);
    }
    return set.size;
  }, [joinedLogs]);

  const totalLogs = joinedLogs.length;

  // PIN submission
  function handleUnlock(e: React.FormEvent) {
    e.preventDefault();
    setPinError(null);

    if (!COACH_PIN) {
      setPinError("COACH PIN NOT CONFIGURED.");
      return;
    }

    if (pinInput.trim() === COACH_PIN) {
      setUnlocked(true);
      setPinInput("");
    } else {
      setPinError("INCORRECT PIN.");
    }
  }

  // Export CSV
  function handleExportCsv() {
    if (!joinedLogs.length) {
      setLoadError("NO DATA TO EXPORT.");
      return;
    }

    setLoadError(null);

    const header = [
      "PLAYER",
      "GRAD_YEAR",
      "LOG_DATE",
      "DISTANCE_FT",
      "TIME_MIN",
      "FLAT_GROUND",
      "BULLPEN",
      "ARM_FEEL",
      "NOTES",
    ];

    const lines: string[] = [];
    lines.push(header.join(","));

    for (const row of joinedLogs) {
      lines.push(
        [
          csvEscape(row.playerName),
          csvEscape(row.gradYear),
          csvEscape(row.logDate),
          csvEscape(
            row.throwingDistance !== null ? String(row.throwingDistance) : ""
          ),
          csvEscape(
            row.throwingTime !== null ? String(row.throwingTime) : ""
          ),
          csvEscape(row.flatGround ? "YES" : "NO"),
          csvEscape(row.bullpen ? "YES" : "NO"),
          csvEscape(
            row.armFeeling !== null ? String(row.armFeeling) : ""
          ),
          csvEscape(row.notes),
        ].join(",")
      );
    }

    const csvContent = lines.join("\n");
    const blob = new Blob([csvContent], {
      type: "text/csv;charset=utf-8;",
    });

    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    const timestamp = new Date().toISOString().slice(0, 10);
    a.download = `winter94-logs-${timestamp}.csv`;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
  }

  // LOCKED VIEW (PIN SCREEN)
  if (!unlocked) {
    return (
      <div
        className={`${bebas.className} min-h-screen bg-slate-950 text-slate-50 flex flex-col items-center text-center uppercase`}
      >
        <main className="w-full max-w-md px-4 pb-24 pt-10 flex-1 space-y-6">
          <header className="flex flex-col items-center gap-1">
            <p className="text-[11px] tracking-[0.32em] text-slate-400">
              WINTER 94
            </p>
            <h1 className="text-4xl tracking-[0.28em]">COACH</h1>
            <p className="mt-2 text-[10px] tracking-[0.22em] text-slate-500">
              ENTER COACH PIN TO VIEW PLAYER LOGS
            </p>
          </header>

          <section className="rounded-3xl border border-slate-800 bg-slate-900 p-5 text-left">
            <p className="text-[11px] tracking-[0.25em] text-slate-400 mb-2">
              COACH PIN
            </p>
            <form onSubmit={handleUnlock} className="space-y-4">
              <input
                type="password"
                maxLength={8}
                value={pinInput}
                onChange={(e) => setPinInput(e.target.value)}
                className="w-full bg-slate-950 rounded-2xl px-3 py-3 text-base text-slate-200 border border-slate-700 focus:border-emerald-400 outline-none tracking-[0.3em] text-center"
              />
              <button
                type="submit"
                className="w-full rounded-2xl bg-emerald-500 py-4 text-lg tracking-[0.3em] font-bold text-black shadow-lg shadow-emerald-500/40 hover:bg-emerald-400"
              >
                UNLOCK
              </button>
            </form>

            {pinError && (
              <p className="mt-3 text-[11px] text-red-400">{pinError}</p>
            )}
          </section>
        </main>

        <BottomNav />
      </div>
    );
  }

  // UNLOCKED VIEW
  return (
    <div
      className={`${bebas.className} min-h-screen bg-slate-950 text-slate-50 flex flex-col items-center text-center uppercase`}
    >
      <main className="w-full max-w-3xl px-4 pb-24 pt-6 flex-1 space-y-5">
        {/* HEADER + EXPORT */}
        <header className="flex flex-col gap-2">
          <div className="flex items-center justify-between">
            <div className="text-left">
              <p className="text-[11px] tracking-[0.32em] text-slate-400">
                WINTER 94
              </p>
              <h1 className="text-4xl tracking-[0.28em]">COACH VIEW</h1>
              <p className="mt-1 text-[10px] tracking-[0.22em] text-slate-500">
                ALL PLAYER LOGS • {PROGRAM_START} → {PROGRAM_END}
              </p>
            </div>

            <div className="flex flex-col items-end gap-2">
              <button
                type="button"
                onClick={handleExportCsv}
                disabled={loading || !joinedLogs.length}
                className="rounded-2xl bg-emerald-500 px-4 py-2 text-[11px] tracking-[0.26em] font-bold text-black shadow-lg shadow-emerald-500/40 hover:bg-emerald-400 disabled:opacity-60 disabled:cursor-not-allowed"
              >
                EXPORT CSV
              </button>
              <p className="text-[9px] text-slate-500 tracking-[0.2em]">
                {totalPlayers} PLAYERS • {totalLogs} LOGS
              </p>
            </div>
          </div>
        </header>

        {/* STATUS / ERRORS */}
        {loading && (
          <p className="text-[11px] tracking-[0.24em] text-slate-400">
            LOADING PLAYER DATA…
          </p>
        )}
        {loadError && (
          <p className="text-[11px] tracking-[0.24em] text-red-400">
            {loadError}
          </p>
        )}

        {/* LOG TABLE */}
        {!loading && !loadError && joinedLogs.length === 0 && (
          <p className="text-[11px] tracking-[0.24em] text-slate-500">
            NO LOGS YET FOR THIS PROGRAM WINDOW.
          </p>
        )}

        {!loading && joinedLogs.length > 0 && (
          <section className="rounded-3xl border border-slate-800 bg-slate-900 p-4 text-left overflow-x-auto">
            <table className="w-full text-[10px] tracking-[0.18em]">
              <thead className="text-slate-400 border-b border-slate-800">
                <tr>
                  <th className="py-2 pr-2 text-left">PLAYER</th>
                  <th className="py-2 pr-2 text-left">GRAD</th>
                  <th className="py-2 pr-2 text-left">DATE</th>
                  <th className="py-2 pr-2 text-right">DIST (FT)</th>
                  <th className="py-2 pr-2 text-right">TIME (MIN)</th>
                  <th className="py-2 pr-2 text-center">FLAT</th>
                  <th className="py-2 pr-2 text-center">PEN</th>
                  <th className="py-2 pr-2 text-center">ARM</th>
                  <th className="py-2 pr-2 text-left">NOTES</th>
                </tr>
              </thead>
              <tbody>
                {joinedLogs.map((row, idx) => (
                  <tr
                    key={`${row.playerName}-${row.logDate}-${idx}`}
                    className={
                      idx % 2 === 0 ? "bg-slate-900" : "bg-slate-950"
                    }
                  >
                    <td className="py-2 pr-2 whitespace-nowrap">
                      {row.playerName}
                    </td>
                    <td className="py-2 pr-2 whitespace-nowrap">
                      {row.gradYear || "—"}
                    </td>
                    <td className="py-2 pr-2 whitespace-nowrap">
                      {row.logDate}
                    </td>
                    <td className="py-2 pr-2 text-right">
                      {row.throwingDistance ?? "—"}
                    </td>
                    <td className="py-2 pr-2 text-right">
                      {row.throwingTime ?? "—"}
                    </td>
                    <td className="py-2 pr-2 text-center">
                      {row.flatGround ? "YES" : "NO"}
                    </td>
                    <td className="py-2 pr-2 text-center">
                      {row.bullpen ? "YES" : "NO"}
                    </td>
                    <td className="py-2 pr-2 text-center">
                      {row.armFeeling ?? "—"}
                    </td>
                    <td className="py-2 pr-2 max-w-[220px] truncate">
                      {row.notes || ""}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </section>
        )}
      </main>

      <BottomNav />
    </div>
  );
}
