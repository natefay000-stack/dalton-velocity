"use client";

import { supabase } from "@/lib/supabase/client";
import BottomNav from "@/components/BottomNav";
import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import {
  PROGRAM_START,
  PROGRAM_END,
  getProgramForDate,
  type DayProgram,
} from "@/lib/program";

type Log = {
  log_date: string;
  throwing_time: number | null;
  throwing_distance: number | null;
  flat_ground: boolean;
  bullpen: boolean;
  arm_feeling: number;
};

const DAILY_TARGET_MINUTES = 45;

export default function SummaryPage() {
  const [logs, setLogs] = useState<Log[]>([]);
  const [loading, setLoading] = useState(true);
  const router = useRouter();

  // ---------------------------------------------------------------------------
  // DATA LOAD
  // ---------------------------------------------------------------------------
  useEffect(() => {
    async function load() {
      if (!supabase) {
        console.warn("Supabase not configured; skipping summary load.");
        setLoading(false);
        return;
      }

      const { data, error } = await supabase
        .from("daily_logs")
        .select(
          "log_date, throwing_time, throwing_distance, flat_ground, bullpen, arm_feeling"
        )
        .order("log_date", { ascending: false })
        .limit(90);

      if (error) {
        console.error("Error loading logs:", error);
        setLogs([]);
      } else {
        setLogs((data || []) as Log[]);
      }
      setLoading(false);
    }

    load();
  }, []);

  // ---------------------------------------------------------------------------
  // LOADING / EMPTY UI
  // ---------------------------------------------------------------------------
  if (loading) {
    return (
      <div className="min-h-screen bg-black text-white flex items-center justify-center">
        Loading…
      </div>
    );
  }

  if (!logs.length) {
    return (
      <div className="min-h-screen bg-black text-white flex flex-col justify-between">
        <main className="flex-1 flex items-center justify-center px-6 text-center">
          <div>
            <p className="text-2xl font-semibold mb-2">No data yet</p>
            <p className="text-sm text-gray-400">
              Log a few days on the TODAY tab and your trends will show up
              here.
            </p>
          </div>
        </main>
        <BottomNav />
      </div>
    );
  }

  // ---------------------------------------------------------------------------
  // DERIVED METRICS
  // ---------------------------------------------------------------------------
  const todayISO = new Date().toISOString().split("T")[0];
  const todayLog =
    logs.find((l) => l.log_date === todayISO) || (logs[0] as Log | undefined);

  const todayMinutes = todayLog?.throwing_time || 0;
  const todayDistance = todayLog?.throwing_distance || 0;
  const todayArmFeel = todayLog?.arm_feeling ?? null;
  const todayBullpen = !!todayLog?.bullpen;

  const completionPercent = Math.max(
    0,
    Math.min(
      100,
      Math.round((todayMinutes / DAILY_TARGET_MINUTES) * 100 || 0)
    )
  );

  const intensity =
    todayMinutes === 0
      ? "Off"
      : todayMinutes < DAILY_TARGET_MINUTES * 0.5
      ? "Light"
      : todayMinutes < DAILY_TARGET_MINUTES * 0.9
      ? "Medium"
      : "High";

  const throwingDays = logs.filter((l) => (l.throwing_time || 0) > 0).length;
  const totalMinutes = logs.reduce((s, l) => s + (l.throwing_time || 0), 0);
  const avgArmFeel = logs.length
    ? (
        logs.reduce((s, l) => s + (l.arm_feeling || 0), 0) / logs.length
      ).toFixed(1)
    : "—";
  const flatGroundDays = logs.filter((l) => l.flat_ground).length;
  const bullpenDays = logs.filter((l) => l.bullpen).length;
  const streak = calculateCurrentStreak(logs);

  const last7 = [...logs].slice(0, 7).reverse();

  const baseLabel = (() => {
    if (completionPercent >= 100) return "Scored at home";
    if (completionPercent >= 75) return "Rounding 3rd base";
    if (completionPercent >= 50) return "On 2nd base";
    if (completionPercent >= 25) return "On 1st base";
    if (completionPercent > 0) return "Out of the box";
    return "At the plate";
  })();

  const distanceLogDays = logs.filter(
    (l) => l.throwing_distance && l.throwing_distance > 0
  ).length;

  // ---------------------------------------------------------------------------
  // RENDER
  // ---------------------------------------------------------------------------

  return (
    <div className="min-h-screen bg-black text-white pt-12 pb-32">
      <div className="px-6 space-y-8">
        {/* HEADER */}
        <div className="text-center mb-2">
          <h1 className="text-5xl font-black tracking-[0.2em]">SUMMARY</h1>
          <p className="text-xs tracking-[0.3em] text-gray-400 mt-1">
            WINTER 94 PROGRAM
          </p>
          <p className="text-sm text-gray-500 mt-2">
            {throwingDays} THROWING DAYS • {streak}-DAY STREAK •{" "}
            {flatGroundDays + bullpenDays} LIVE SESSIONS
          </p>
          <p className="text-xs text-gray-500 mt-1">
            TOTAL THROWING TIME: {totalMinutes} MIN • AVG ARM FEEL:{" "}
            {avgArmFeel}/10
          </p>
        </div>

        {/* TODAY'S WORK — DIAMOND PROGRESS */}
        <section className="rounded-3xl bg-[#101015] px-6 py-7 shadow-lg">
          <p className="text-xs tracking-[0.25em] text-gray-400 mb-3">TODAY</p>
          <div className="flex flex-col items-center gap-3">
            <DiamondProgress percent={completionPercent} />
            <p className="text-3xl font-black">
              {completionPercent}% COMPLETE
            </p>
            <p className="text-gray-400 text-sm uppercase tracking-[0.2em]">
              {baseLabel}
            </p>
          </div>
        </section>

        {/* TODAY STATS ROW */}
        <section className="grid grid-cols-3 gap-4">
          {/* Arm Feel */}
          <div className="rounded-3xl bg-[#1c1c1e] px-4 py-5 flex flex-col items-center text-center">
            <div className="mb-2 flex items-center justify-center">
              <div className="h-10 w-10 rounded-full border-2 border-green-500 flex items-center justify-center text-lg font-bold">
                {todayArmFeel ?? "—"}
              </div>
            </div>
            <p className="text-[11px] tracking-[0.2em] text-gray-400">
              ARM FEEL
            </p>
            <p className="text-lg font-semibold">
              {todayArmFeel !== null ? `${todayArmFeel}/10` : "NO LOG"}
            </p>
          </div>

          {/* Throwing Time */}
          <div className="rounded-3xl bg-[#1c1c1e] px-4 py-5 flex flex-col items-center text-center">
            <p className="text-2xl font-bold">
              {todayMinutes}
              <span className="text-sm ml-1 text-gray-300">MIN</span>
            </p>
            <p className="text-[11px] tracking-[0.2em] text-gray-400 mt-1">
              THROWING TIME
            </p>
            <p className="text-xs text-gray-500 mt-1">
              TARGET {DAILY_TARGET_MINUTES} MIN
            </p>
          </div>

          {/* Intensity */}
          <div className="rounded-3xl bg-[#1c1c1e] px-4 py-5 flex flex-col items-center text-center">
            <span
              className={`px-3 py-1 rounded-full text-sm font-semibold uppercase tracking-[0.1em] ${
                intensity === "High"
                  ? "bg-red-500/20 text-red-400"
                  : intensity === "Medium"
                  ? "bg-blue-500/20 text-blue-400"
                  : intensity === "Light"
                  ? "bg-green-500/20 text-green-400"
                  : "bg-gray-600/30 text-gray-300"
              }`}
            >
              {intensity}
            </span>
            <p className="text-[11px] tracking-[0.2em] text-gray-400 mt-2">
              INTENSITY
            </p>
            <p className="text-xs text-gray-500 mt-1">
              {todayBullpen ? "BULLPEN DAY" : "FLAT / CATCH / OFF"}
            </p>
          </div>
        </section>

        {/* DISTANCE PROGRESS – ASPIRATIONAL PROGRAM RAMP */}
        <section className="rounded-3xl bg-[#101015] px-6 py-6 shadow-lg">
          <div className="flex items-center justify-between mb-3">
            <div>
              <p className="text-lg font-semibold">Distance Progress</p>
              <p className="text-xs text-gray-500 mt-1">
                Climbing the Winter 94 ramp • Distance days:{" "}
                <span className="text-gray-200">{distanceLogDays}</span>
              </p>
            </div>
          </div>

          <DistanceLine logs={logs} />

          <div className="flex justify-between text-xs text-gray-400 mt-3">
            <span>
              Today max:{" "}
              <span className="text-gray-100">
                {todayDistance ? `${todayDistance} ft` : "—"}
              </span>
            </span>
            <span className="text-right">
              Program distance days logged:{" "}
              <span className="text-gray-100">{distanceLogDays}</span>
            </span>
          </div>
        </section>

        {/* LAST 7 DAYS – MINI DIAMONDS */}
        <section>
          <p className="text-center text-2xl font-bold mb-3 tracking-[0.15em]">
            LAST 7 DAYS
          </p>
          <div className="rounded-3xl bg-[#101015] px-4 py-4 flex justify-between items-end gap-2">
            {last7.map((log) => {
              const pct = Math.max(
                0,
                Math.min(
                  100,
                  Math.round(
                    ((log.throwing_time || 0) / DAILY_TARGET_MINUTES) * 100
                  )
                )
              );
              const hasWork = (log.throwing_time || 0) > 0;
              return (
                <div
                  key={log.log_date}
                  className="flex flex-col items-center gap-1"
                >
                  <MiniDiamond percent={pct} active={hasWork} />
                  <span className="text-[10px] text-gray-400">
                    {new Date(log.log_date).toLocaleDateString("en-US", {
                      weekday: "short",
                    })}
                  </span>
                </div>
              );
            })}
          </div>
        </section>

        {/* RECENT SESSIONS LIST – CLICKABLE TO TODAY TAB */}
        <section>
          <p className="text-2xl font-bold mb-3 text-center tracking-[0.15em]">
            RECENT SESSIONS
          </p>
          <div className="space-y-4">
            {logs.slice(0, 7).map((log) => (
              <button
                key={log.log_date}
                type="button"
                onClick={() => router.push(`/today?date=${log.log_date}`)}
                className="w-full text-left rounded-2xl bg-[#1c1c1e] p-5 flex justify-between items-center border border-transparent hover:border-emerald-400/60 active:scale-[0.98] transition cursor-pointer"
              >
                <div>
                  <p className="text-lg font-bold">
                    {new Date(log.log_date).toLocaleDateString("en-US", {
                      weekday: "short",
                      month: "short",
                      day: "numeric",
                    })}
                    {log.bullpen && " • Bullpen"}
                    {log.flat_ground && !log.bullpen && " • Flat Ground"}
                  </p>
                  <p className="text-gray-400 text-sm">
                    {(log.throwing_time || 0)} min •{" "}
                    {(log.throwing_distance || 0)} ft
                  </p>
                  <p className="text-[11px] text-gray-500 mt-1">
                    Tap to open this day
                  </p>
                </div>
                <p
                  className={`text-4xl font-black ${
                    log.arm_feeling >= 8
                      ? "text-green-400"
                      : log.arm_feeling >= 6
                      ? "text-yellow-400"
                      : "text-red-400"
                  }`}
                >
                  {log.arm_feeling}
                </p>
              </button>
            ))}
          </div>
        </section>
      </div>

      <BottomNav />
    </div>
  );
}

// ===========================================================================
// HELPERS & SMALL COMPONENTS
// ===========================================================================

function calculateCurrentStreak(logs: Log[]) {
  let streak = 0;
  const today = new Date();

  for (let i = 0; i < 90; i++) {
    const date = new Date();
    date.setDate(today.getDate() - i);
    const dateStr = date.toISOString().split("T")[0];

    const hasThrow = logs.some(
      (l) => l.log_date === dateStr && (l.throwing_time || 0) > 0
    );

    if (hasThrow) {
      streak++;
    } else if (i > 0) {
      break;
    }
  }

  return streak;
}

function normalizeDateLocal(d: Date) {
  const nd = new Date(d);
  nd.setHours(0, 0, 0, 0);
  return nd;
}

// ---------------------------------------------------------------------------
// ASPIRATIONAL DISTANCE GRAPH (monotonic ramp)
// ---------------------------------------------------------------------------
function DistanceLine({ logs }: { logs: Log[] }) {
  const start = normalizeDateLocal(new Date(PROGRAM_START));
  const end = normalizeDateLocal(new Date(PROGRAM_END));

  // Map logs by date
  const logsByDate = new Map<string, Log>();
  for (const l of logs) {
    logsByDate.set(l.log_date, l);
  }

  type Point = {
    key: string;
    prog: number | null;
    actual: number | null;
  };

  const series: Point[] = [];
  for (let d = new Date(start); d <= end; d.setDate(d.getDate() + 1)) {
    const key = d.toISOString().split("T")[0];

    const dayProgram: DayProgram = getProgramForDate(key);
    const progMatch = (dayProgram.throwingDistance || "").match(/(\d+)/);
    const progVal = progMatch ? parseInt(progMatch[1], 10) : 0;
    const prog = progVal > 0 ? progVal : null;

    const log = logsByDate.get(key);
    const actual =
      log && log.throwing_distance && log.throwing_distance > 0
        ? log.throwing_distance
        : null;

    series.push({ key, prog, actual });
  }

  // 🔥 Make program ramp monotonic (always climbing, no dips)
  let runningProg = 0;
  for (let i = 0; i < series.length; i++) {
    const p = series[i];

    if (p.prog !== null) {
      runningProg = Math.max(runningProg, p.prog);
    }

    if (runningProg === 0) {
      series[i].prog = null; // before first distance appears, keep null
    } else {
      series[i].prog = runningProg; // afterwards, ramp can only stay flat or go up
    }
  }

  const progVals = series.map((p) => p.prog || 0);
  const actualVals = series.map((p) => p.actual || 0);
  const anyProg = progVals.some((v) => v > 0);
  const anyActual = actualVals.some((v) => v > 0);

  if (!anyProg && !anyActual) {
    return (
      <div className="py-6 text-center text-sm text-gray-500">
        Log distance on a few days and your ramp will show up here.
      </div>
    );
  }

  const maxY = Math.max(
    anyProg ? Math.max(...progVals) : 0,
    anyActual ? Math.max(...actualVals) : 0
  );
  const safeMaxY = maxY || 1;

  const width = 100;
  const height = 40;
  const padX = 6;
  const padTop = 6;
  const padBottom = 10;
  const usableW = width - padX * 2;
  const usableH = height - padTop - padBottom;

  const n = series.length;
  const stepX = n > 1 ? usableW / (n - 1) : 0;

  // Find last index with a logged actual distance
  let lastLoggedIndex = -1;
  series.forEach((p, i) => {
    if (p.actual !== null) lastLoggedIndex = i;
  });

  // PROGRAM RAMP (continuous)
  let programPath = "";
  let lastProgY: number | null = null;

  series.forEach((p, i) => {
    const x = padX + stepX * i;

    if (p.prog !== null) {
      lastProgY = padTop + usableH * (1 - p.prog / safeMaxY);
    }

    if (lastProgY === null) return;

    const y = lastProgY;

    if (!programPath) {
      programPath = `M ${x} ${y}`;
    } else {
      programPath += ` L ${x} ${y}`;
    }
  });

  // FILL UNDER RAMP UP TO LAST LOGGED DAY
  let fillPath = "";
  if (lastLoggedIndex >= 0) {
    let firstProgIndex = series.findIndex((p) => p.prog !== null);
    if (firstProgIndex < 0) firstProgIndex = 0;

    const startIndex = Math.min(firstProgIndex, lastLoggedIndex);
    const endIndex = lastLoggedIndex;

    const baseY = height - padBottom;
    const startX = padX + stepX * startIndex;
    fillPath += `M ${startX} ${baseY} `;

    let carryProgY: number | null = null;

    for (let i = startIndex; i <= endIndex; i++) {
      const p = series[i];
      const x = padX + stepX * i;

      if (p.prog !== null) {
        carryProgY = padTop + usableH * (1 - p.prog / safeMaxY);
      }

      if (carryProgY === null) continue;

      fillPath += `L ${x} ${carryProgY} `;
    }

    const endX = padX + stepX * endIndex;
    fillPath += `L ${endX} ${baseY} Z`;
  }

  // ACTUAL LINE (only where logged)
  let actualPath = "";
  let drawingActual = false;

  series.forEach((p, i) => {
    if (p.actual === null) {
      drawingActual = false;
      return;
    }

    const x = padX + stepX * i;
    const y = padTop + usableH * (1 - p.actual / safeMaxY);

    if (!drawingActual) {
      actualPath += `M ${x} ${y}`;
      drawingActual = true;
    } else {
      actualPath += ` L ${x} ${y}`;
    }
  });

  const lastActual =
    lastLoggedIndex >= 0 ? series[lastLoggedIndex] : null;

  const programStartLabel = new Date(start).toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
  });
  const programEndLabel = new Date(end).toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
  });

  return (
    <div>
      <svg viewBox={`0 0 ${width} ${height}`} className="w-full h-32">
        <defs>
          <linearGradient id="rampFill" x1="0%" y1="0%" x2="0%" y2="100%">
            <stop offset="0%" stopColor="#ef4444dd" />
            <stop offset="100%" stopColor="#7f1d1ddd" />
          </linearGradient>

          <linearGradient
            id="programStroke"
            x1="0%"
            y1="0%"
            x2="100%"
            y2="0%"
          >
            <stop offset="0%" stopColor="#4b5563" />
            <stop offset="100%" stopColor="#6b7280" />
          </linearGradient>

          <linearGradient
            id="actualStroke"
            x1="0%"
            y1="0%"
            x2="100%"
            y2="0%"
          >
            <stop offset="0%" stopColor="#22c55e" />
            <stop offset="100%" stopColor="#0ea5e9" />
          </linearGradient>
        </defs>

        {/* baseline */}
        <line
          x1={padX}
          y1={height - padBottom}
          x2={width - padX}
          y2={height - padBottom}
          stroke="#111827"
          strokeWidth={0.8}
        />

        {/* ramp fill */}
        {fillPath && (
          <path d={fillPath} fill="url(#rampFill)" opacity={0.95} />
        )}

        {/* program ramp */}
        {programPath && (
          <path
            d={programPath}
            fill="none"
            stroke="url(#programStroke)"
            strokeWidth={1.2}
            strokeLinecap="round"
            opacity={0.9}
          />
        )}

        {/* actual logged line */}
        {actualPath && (
          <path
            d={actualPath}
            fill="none"
            stroke="url(#actualStroke)"
            strokeWidth={1.8}
            strokeLinecap="round"
          />
        )}

        {/* last logged point */}
        {lastActual &&
          lastActual.actual !== null &&
          lastLoggedIndex >= 0 && (() => {
            const x = padX + stepX * lastLoggedIndex;
            const y =
              padTop +
              usableH *
                (1 -
                  (lastActual.actual as number) / safeMaxY);

            return (
              <g>
                <circle
                  cx={x}
                  cy={y}
                  r={2.8}
                  fill="#22c55e"
                  stroke="#0f766e"
                  strokeWidth={1}
                />
                <text
                  x={x + 3}
                  y={y - 2}
                  className="fill-slate-100"
                  fontSize={3}
                >
                  {lastActual.actual} ft
                </text>
              </g>
            );
          })()}
      </svg>

      <div className="mt-1 flex justify-between text-[10px] text-gray-500">
        <span>{programStartLabel}</span>
        <span>CLIMBING THE RAMP</span>
        <span>{programEndLabel}</span>
      </div>
    </div>
  );
}

function DiamondProgress({ percent }: { percent: number }) {
  const clamped = Math.max(0, Math.min(100, percent));

  return (
    <svg
      viewBox="0 0 100 100"
      className="h-40 w-40 drop-shadow-[0_0_20px_rgba(34,197,94,0.35)]"
    >
      <path
        d="M50 5 L95 50 L50 95 L5 50 Z"
        fill="none"
        stroke="#27272f"
        strokeWidth={6}
      />
      <defs>
        <linearGradient
          id="diamondGradient"
          x1="0%"
          y1="0%"
          x2="100%"
          y2="100%"
        >
          <stop offset="0%" stopColor="#22c55e" />
          <stop offset="100%" stopColor="#0ea5e9" />
        </linearGradient>
      </defs>
      <path
        d="M50 5 L95 50 L50 95 L5 50 Z"
        fill="none"
        stroke="url(#diamondGradient)"
        strokeWidth={6}
        strokeLinecap="round"
        pathLength={100}
        strokeDasharray={100}
        strokeDashoffset={100 - clamped}
      />
    </svg>
  );
}

function MiniDiamond({
  percent,
  active,
}: {
  percent: number;
  active: boolean;
}) {
  const color =
    percent >= 100
      ? "bg-gradient-to-br from-emerald-400 to-cyan-400"
      : percent >= 50
      ? "bg-emerald-500/70"
      : percent > 0
      ? "bg-emerald-500/30"
      : "bg-transparent";

  return (
    <div className="h-6 w-6 rotate-45 border border-gray-600 flex items-center justify-center">
      <div
        className={`h-4 w-4 rounded-[4px] ${
          active ? color : "bg-transparent"
        }`}
      />
    </div>
  );
}
