"use client";

import { useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import { supabase } from "@/lib/supabase/client";
import BottomNav from "@/components/BottomNav";
import {
  PROGRAM_START,
  PROGRAM_END,
  DayProgram,
  getProgramForDate,
} from "@/lib/program";
import { Bebas_Neue } from "next/font/google";

const bebas = Bebas_Neue({ subsets: ["latin"], weight: "400" });

type DailyLog = {
  log_date: string;
  throwing_time: number | null;
  throwing_distance: number | null;
  flat_ground: boolean;
  bullpen: boolean;
  arm_feeling: number | null;
};

function parseDate(key: string): Date {
  const [y, m, d] = key.split("-").map(Number);
  return new Date(y, m - 1, d);
}

function toDateKey(date: Date): string {
  return date.toISOString().split("T")[0];
}

function getDateKeysInRange(startKey: string, endKey: string): string[] {
  const keys: string[] = [];
  const start = parseDate(startKey);
  const end = parseDate(endKey);

  const d = new Date(start);
  while (d <= end) {
    keys.push(toDateKey(d));
    d.setDate(d.getDate() + 1);
  }
  return keys;
}

function formatMonthLabel(date: Date): string {
  return date.toLocaleDateString("en-US", {
    month: "long",
    year: "numeric",
  });
}

function formatRange(startKey: string, endKey: string): string {
  const start = parseDate(startKey);
  const end = parseDate(endKey);

  const sameYear = start.getFullYear() === end.getFullYear();
  const startStr = start.toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    ...(sameYear ? {} : { year: "numeric" }),
  });

  const endStr = end.toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    year: "numeric",
  });

  return `${startStr} – ${endStr}`;
}

function shortenTimeLabel(time?: string): string {
  if (!time) return "";
  return time
    .replace(/minutes/gi, "min")
    .replace(/minute/gi, "min")
    .trim();
}

function getHasActivity(log: DailyLog | undefined): boolean {
  if (!log) return false;
  return (
    (log.throwing_time ?? 0) > 0 ||
    (log.throwing_distance ?? 0) > 0 ||
    log.flat_ground ||
    log.bullpen ||
    log.arm_feeling !== null
  );
}

export default function CalendarPage() {
  const router = useRouter();

  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [logs, setLogs] = useState<DailyLog[]>([]);
  const [user, setUser] = useState<any>(null); // for the indicator

  const dateKeys = useMemo(
    () => getDateKeysInRange(PROGRAM_START, PROGRAM_END),
    []
  );
  const totalDays = dateKeys.length;

  // Months inside program range (e.g., Dec 2025, Jan 2026, Feb 2026)
  const months = useMemo(() => {
    const first = parseDate(PROGRAM_START);
    const last = parseDate(PROGRAM_END);

    const list: { year: number; month: number }[] = [];
    const d = new Date(first.getFullYear(), first.getMonth(), 1);

    while (d <= last) {
      list.push({ year: d.getFullYear(), month: d.getMonth() });
      d.setMonth(d.getMonth() + 1);
    }
    return list;
  }, []);

  const [monthIndex, setMonthIndex] = useState(0);

  useEffect(() => {
    async function load() {
      setLoading(true);
      setError(null);

      // 🔑 Get the current authenticated user
      const {
        data: { user },
        error: userError,
      } = await supabase.auth.getUser();

      if (userError || !user) {
        console.warn("No authenticated user; calendar will be empty.");
        setUser(null);
        setLogs([]);
        setLoading(false);
        return;
      }

      setUser(user);

      // 🔑 Load only this user's logs for the program window
      const { data, error } = await supabase
        .from("daily_logs")
        .select(
          "log_date, throwing_time, throwing_distance, flat_ground, bullpen, arm_feeling"
        )
        .eq("user_id", user.id)
        .gte("log_date", PROGRAM_START)
        .lte("log_date", PROGRAM_END)
        .order("log_date", { ascending: true });

      if (error) {
        console.error("Error loading calendar logs:", error);
        setError("COULD NOT LOAD CALENDAR.");
      } else if (data) {
        setLogs(data as DailyLog[]);
      }

      setLoading(false);
    }

    load();
  }, []);

  const logByDate = useMemo(() => {
    const map: Record<string, DailyLog> = {};
    for (const log of logs) {
      map[log.log_date] = log;
    }
    return map;
  }, [logs]);

  const todayKey = toDateKey(new Date());

  const { completedDays } = useMemo(() => {
    let completed = 0;
    for (const key of dateKeys) {
      if (getHasActivity(logByDate[key])) completed += 1;
    }
    return { completedDays: completed };
  }, [dateKeys, logByDate]);

  const completionPct =
    totalDays > 0 ? Math.round((completedDays / totalDays) * 100) : 0;

  // Current month info
  const currentMonth = months[monthIndex];
  const monthFirst = new Date(currentMonth.year, currentMonth.month, 1);
  const monthLabel = formatMonthLabel(monthFirst);
  const startDow = monthFirst.getDay(); // 0 = Sun
  const daysInMonth = new Date(
    currentMonth.year,
    currentMonth.month + 1,
    0
  ).getDate();

  // Build cells for grid
  const cells: { key: string | null; date?: Date }[] = [];
  for (let i = 0; i < startDow; i++) {
    cells.push({ key: null });
  }
  for (let day = 1; day <= daysInMonth; day++) {
    const d = new Date(currentMonth.year, currentMonth.month, day);
    const key = toDateKey(d);
    if (key < PROGRAM_START || key > PROGRAM_END) {
      cells.push({ key: null });
    } else {
      cells.push({ key, date: d });
    }
  }

  if (loading) {
    return (
      <div
        className={`${bebas.className} min-h-screen bg-slate-950 text-slate-50 flex flex-col`}
      >
        <main className="flex-1 flex items-center justify-center text-2xl tracking-widest uppercase">
          LOADING CALENDAR…
        </main>
        <BottomNav />
      </div>
    );
  }

  return (
    <div
      className={`${bebas.className} relative min-h-screen bg-slate-950 text-slate-50 flex flex-col items-center text-center uppercase`}
    >
      {/* LOGIN INDICATOR (tiny, top-right) */}
      <div className="absolute top-3 right-4 flex items-center gap-1">
        {user ? (
          <>
            <span className="h-2 w-2 rounded-full bg-emerald-400" />
            <span className="text-[9px] tracking-[0.15em] text-slate-400">
              {user.email?.slice(0, 4).toLowerCase()}…
            </span>
          </>
        ) : (
          <button
            type="button"
            onClick={() => router.push("/login")}
            className="flex items-center gap-1"
          >
            <span className="h-2 w-2 rounded-full bg-red-500" />
            <span className="text-[9px] tracking-[0.15em] text-red-400 underline">
              OFFLINE
            </span>
          </button>
        )}
      </div>

      <main className="w-full max-w-md px-4 pb-24 pt-6 flex-1 space-y-6">
        {/* HEADER + COACH LINK */}
        <header className="flex flex-col gap-2">
          <div className="flex items-center justify-between">
            <div className="text-left">
              <p className="text-[10px] tracking-[0.3em] text-slate-400">
                WINTER 94
              </p>
              <h1 className="text-3xl tracking-[0.25em]">CALENDAR</h1>
              <p className="text-[11px] tracking-[0.22em] text-slate-500 mt-1">
                {formatRange(PROGRAM_START, PROGRAM_END)}
              </p>
            </div>

            <Link
              href="/coach"
              className="text-[9px] tracking-[0.22em] border border-slate-700 rounded-full px-3 py-1 text-slate-300 hover:bg-slate-900"
            >
              COACH VIEW
            </Link>
          </div>
        </header>

        {/* DIAMOND COMPLETION CARD */}
        <section className="rounded-3xl border border-slate-800 bg-slate-900 p-5">
          <p className="text-lg tracking-widest text-slate-200">
            PROGRAM COMPLETION
          </p>
          <p className="mt-1 text-[11px] tracking-[0.22em] text-slate-500">
            {completedDays} OF {totalDays} DAYS LOGGED
          </p>

          <div className="mt-4 flex justify-center">
            <div className="relative w-24 h-24">
              <div className="absolute inset-0 rotate-45 rounded-2xl bg-gradient-to-br from-emerald-400 to-lime-500 border border-emerald-200 shadow-[0_0_25px_rgba(16,185,129,0.6)]" />
              <div className="absolute inset-[5px] rotate-45 rounded-2xl bg-slate-950 border border-emerald-300" />
              <div className="absolute inset-0 flex items-center justify-center">
                <div className="-rotate-45 flex flex-col items-center leading-none">
                  <span className="text-2xl">{completionPct}</span>
                  <span className="text-[10px] tracking-[0.25em] mt-1">
                    PCT
                  </span>
                </div>
              </div>
            </div>
          </div>
        </section>

        {/* MONTH SWITCHER + CALENDAR */}
        <section className="rounded-3xl border border-slate-800 bg-slate-900 p-5">
          {/* Month header with prev/next */}
          <div className="flex items-center justify-between mb-4">
            <button
              type="button"
              disabled={monthIndex === 0}
              onClick={() =>
                monthIndex > 0 && setMonthIndex((i) => i - 1)
              }
              className={`text-[10px] tracking-[0.16em] px-2 py-1 rounded-full border bg-gradient-to-r from-emerald-600 to-lime-400 ${
                monthIndex > 0
                  ? "border-emerald-500 text-slate-950 hover:brightness-110"
                  : "border-slate-800 text-slate-600 opacity-50 cursor-default"
              }`}
            >
              ◀
            </button>

            <p className="text-lg tracking-[0.25em]">{monthLabel}</p>

            <button
              type="button"
              disabled={monthIndex === months.length - 1}
              onClick={() =>
                monthIndex < months.length - 1 &&
                setMonthIndex((i) => i + 1)
              }
              className={`text-[10px] tracking-[0.16em] px-2 py-1 rounded-full border bg-gradient-to-r from-lime-400 to-emerald-600 ${
                monthIndex < months.length - 1
                  ? "border-emerald-500 text-slate-950 hover:brightness-110"
                  : "border-slate-800 text-slate-600 opacity-50 cursor-default"
              }`}
            >
              ▶
            </button>
          </div>

          {/* Day-of-week header */}
          <div className="grid grid-cols-7 text-[10px] tracking-[0.24em] text-slate-500 mb-2">
            <span>SUN</span>
            <span>MON</span>
            <span>TUE</span>
            <span>WED</span>
            <span>THU</span>
            <span>FRI</span>
            <span>SAT</span>
          </div>

          {/* Calendar grid */}
          <div className="grid grid-cols-7 gap-2 text-[11px]">
            {cells.map((cell, idx) => {
              if (!cell.key || !cell.date) {
                return <div key={idx} className="h-16" />;
              }

              const key = cell.key;
              const log = logByDate[key];
              const hasActivity = getHasActivity(log);
              const plan: DayProgram = getProgramForDate(key);
              const shortTime = shortenTimeLabel(plan.throwingTime);
              const shortDistance = plan.throwingDistance || "";

              const isFuture = key > todayKey;
              const pillText = hasActivity ? "LOGGED" : isFuture ? "-" : "—";

              return (
                <button
                  key={key}
                  type="button"
                  onClick={() => router.push(`/today?date=${key}`)}
                  className={`h-20 rounded-2xl border flex flex-col items-center justify-between px-1 py-1 ${
                    hasActivity
                      ? "border-emerald-500 bg-slate-950"
                      : "border-slate-700 bg-slate-900"
                  } hover:border-emerald-400 transition`}
                >
                  <div className="w-full flex justify-between items-center px-1">
                    <span className="text-sm">
                      {cell.date.getDate()}
                    </span>
                  </div>

                  <div className="flex flex-col items-center leading-tight text-[9px] text-slate-400">
                    {shortDistance && (
                      <span>{shortDistance.toUpperCase()}</span>
                    )}
                    {shortTime && <span>{shortTime.toUpperCase()}</span>}
                  </div>

                  <div
                    className={`mt-1 w-full text-[9px] tracking-[0.18em] rounded-full px-1 py-[2px] ${
                      hasActivity
                        ? "bg-emerald-500 text-slate-950"
                        : "bg-slate-800 text-slate-300"
                    }`}
                  >
                    {pillText}
                  </div>
                </button>
              );
            })}
          </div>
        </section>

        {error && (
          <p className="text-xs tracking-widest text-red-300 bg-red-950/40 border border-red-800/60 rounded-lg px-3 py-2">
            {error}
          </p>
        )}
      </main>

      <BottomNav />
    </div>
  );
}
