"use client";

import { supabase } from "@/lib/supabase/client";
import BottomNav from "@/components/BottomNav";
import { useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
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

type DayWithStatus = {
  dateKey: string;
  dateLabel: string;
  program: DayProgram;
  log?: DailyLog;
  status: "off" | "done" | "logged" | "missed";
};

export default function TodayPage() {
  const [logs, setLogs] = useState<DailyLog[]>([]);
  const [loading, setLoading] = useState(true);
  const [user, setUser] = useState<any>(null); // for login indicator
  const router = useRouter();

  useEffect(() => {
    async function load() {
      setLoading(true);

      // Get current user
      const {
        data: { user },
        error: userError,
      } = await supabase.auth.getUser();

      if (userError || !user) {
        console.warn("No authenticated user on dashboard.");
        setUser(null);
        setLogs([]);
        setLoading(false);
        return;
      }

      setUser(user);

      // Load only this user's logs
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
        console.error("Error loading home logs:", error);
        setLogs([]);
      } else {
        setLogs((data || []) as DailyLog[]);
      }

      setLoading(false);
    }

    load();
  }, []);

  const days: DayWithStatus[] = useMemo(() => {
    const list: DayWithStatus[] = [];

    const start = new Date(PROGRAM_START);
    const end = new Date(PROGRAM_END);
    const logsByDate = new Map<string, DailyLog>();
    for (const log of logs) logsByDate.set(log.log_date, log);

    for (let d = new Date(start); d <= end; d.setDate(d.getDate() + 1)) {
      const key = d.toISOString().split("T")[0];
      const program = getProgramForDate(key);
      const log = logsByDate.get(key);

      const hasWork =
        program.throwingTime ||
        program.throwingDistance ||
        program.flatGround ||
        program.bullpen;

      let status: DayWithStatus["status"] = "off";

      if (!hasWork && !log) status = "off";
      else if (log && (log.throwing_time || 0) > 0) status = "done";
      else if (log) status = "logged";
      else status = "missed";

      const dateLabel = d.toLocaleDateString("en-US", {
        weekday: "short",
        month: "short",
        day: "numeric",
      });

      list.push({
        dateKey: key,
        dateLabel,
        program,
        log,
        status,
      });
    }

    return list;
  }, [logs]);

  if (loading) {
    return (
      <div
        className={`${bebas.className} min-h-screen bg-slate-950 text-white flex items-center justify-center text-3xl`}
      >
        LOADING…
      </div>
    );
  }

  const todayKey = new Date().toISOString().split("T")[0];
  const todayIndex = days.findIndex((d) => d.dateKey === todayKey);
  const todayDay = todayIndex >= 0 ? days[todayIndex] : days[0];
  const dayNumber = todayIndex >= 0 ? todayIndex + 1 : 1;

  const todayProgram = todayDay.program;

  const distance = todayProgram.throwingDistance || "—";
  const time = todayProgram.throwingTime || "—";
  const flat = todayProgram.flatGround ? "YES" : "NO";
  const pen = todayProgram.bullpen ? "YES" : "OFF";

  const streak = (() => {
    if (todayIndex < 0) return 0;
    let count = 0;
    for (let i = todayIndex; i >= 0; i--) {
      if (days[i].status === "done") count++;
      else break;
    }
    return count;
  })();

  const armFeel = todayDay.log?.arm_feeling ?? null;
  const sessionsDone = days.filter((d) => d.status === "done").length;

  return (
    <div
      className={`${bebas.className} relative min-h-screen bg-slate-950 text-slate-50 flex flex-col items-center text-center uppercase`}
    >
      {/* LOGIN INDICATOR (tiny, top-right, OFFLINE is clickable) */}
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

      <main className="w-full max-w-md px-4 pb-10 pt-6 flex-1">
        {/* HEADER */}
        <h1 className="text-4xl tracking-widest mb-2">DALTON’S DASHBOARD</h1>
        <p className="text-sm tracking-widest text-slate-400">
          DAY {dayNumber} • 🔥 {streak}-DAY STREAK
        </p>

        {/* TODAY’S SESSION */}
        <section className="mt-5 w-full flex justify-center">
          <div className="w-full max-w-sm rounded-2xl border border-slate-800 bg-slate-900 p-6 shadow-xl">
            {/* Header = distance + time */}
            <p className="text-3xl tracking-widest text-white mb-3">
              {distance} • {time}
            </p>

            {/* Focus boxes */}
            <div className="mt-4 grid grid-cols-2 gap-4">
              <Focus label="DISTANCE" icon="📏" value={distance} />
              <Focus label="TIME" icon="⏱️" value={time} />
              <Focus label="FLAT GROUND" icon="🎯" value={flat} />
              <Focus
                label="BULLPEN"
                icon="⚾"
                value={pen}
                danger={pen === "OFF"}
              />
            </div>

            {/* LOG TODAY BUTTON (bigger) */}
            <button
              type="button"
              onClick={() => router.push("/today")}
              className="mt-7 w-full rounded-xl bg-emerald-500 py-4 text-2xl tracking-widest text-slate-950 shadow-lg hover:bg-emerald-400 transition"
            >
              LOG TODAY
            </button>
          </div>
        </section>

        {/* SUMMARY / CALENDAR */}
        <section className="mt-6 grid grid-cols-2 gap-4 w-full max-w-sm mx-auto">
          <NavBox
            label="SUMMARY"
            icon="📊"
            onClick={() => router.push("/summary")}
          />
          <NavBox
            label="CALENDAR"
            icon="🗓️"
            onClick={() => router.push("/calendar")}
          />
        </section>

        {/* PERFORMANCE SNAPSHOT */}
        <section className="mt-8 w-full flex justify-center">
          <div className="w-full max-w-sm rounded-2xl border border-slate-800 bg-slate-900 p-6 shadow-xl">
            <p className="text-3xl tracking-widest mb-4">
              PERFORMANCE SNAPSHOT
            </p>

            <div className="grid grid-cols-2 gap-5">
              <Snapshot label="SESSIONS DONE" value={`${sessionsDone}`} />
              <Snapshot
                label="ARM FEEL"
                value={armFeel ? `${armFeel}/10` : "—"}
              />
              <Snapshot label="VELO TREND" value="—" />
              <Snapshot label="STREAK" value={`${streak} DAYS`} />
            </div>
          </div>
        </section>

        <p className="mt-8 text-xs tracking-[0.3em] text-slate-600">
          94+ OR BUST
        </p>
      </main>

      <BottomNav />
    </div>
  );
}

/* COMPONENTS */

function Focus({
  label,
  icon,
  value,
  danger,
}: {
  label: string;
  icon: string;
  value: string;
  danger?: boolean;
}) {
  return (
    <div
      className={`rounded-xl border px-4 py-3 ${
        danger
          ? "border-red-600 bg-red-900/40 text-red-200"
          : "border-slate-700 bg-slate-950 text-slate-50"
      }`}
    >
      <p className="text-lg tracking-widest text-slate-300 flex items-center justify-center gap-1">
        {icon} {label}
      </p>
      <p className="text-2xl tracking-widest mt-1">{value}</p>
    </div>
  );
}

function Snapshot({
  label,
  value,
}: {
  label: string;
  value: string;
}) {
  return (
    <div className="rounded-xl border border-slate-700 bg-slate-950 p-4">
      <p className="text-lg tracking-widest text-slate-400">{label}</p>
      <p className="text-3xl tracking-widest mt-1 text-white">{value}</p>
    </div>
  );
}

function NavBox({
  label,
  icon,
  onClick,
}: {
  label: string;
  icon: string;
  onClick: () => void;
}) {
  return (
    <button
      onClick={onClick}
      className="rounded-xl border border-slate-700 bg-slate-900 py-5 text-xl tracking-widest hover:border-slate-500 transition flex flex-col items-center justify-center"
    >
      <span className="text-2xl mb-1">{icon}</span>
      {label}
    </button>
  );
}
