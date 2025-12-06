"use client";

import { useRouter } from "next/navigation";
import {
  useEffect,
  useMemo,
  useRef,
  useState,
  type TouchEvent,
} from "react";
import { supabase } from "@/lib/supabase/client";
import BottomNav from "@/components/BottomNav";
import {
  PROGRAM_START,
  PROGRAM_END,
  type DayProgram,
  getProgramForDate,
} from "@/lib/program";
import { Bebas_Neue } from "next/font/google";

const bebas = Bebas_Neue({ subsets: ["latin"], weight: "400" });

// ------------------------------
// DATE HELPERS
// ------------------------------

function normalizeDate(d: Date) {
  const nd = new Date(d);
  nd.setHours(0, 0, 0, 0);
  return nd;
}

function toDateKey(date: Date): string {
  const year = date.getFullYear();
  const month = `${date.getMonth() + 1}`.padStart(2, "0");
  const day = `${date.getDate()}`.padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function formatPrettyDate(date: Date): string {
  return date
    .toLocaleDateString("en-US", {
      weekday: "short",
      month: "short",
      day: "numeric",
      year: "numeric",
    })
    .toUpperCase();
}

const PROGRAM_START_DATE = normalizeDate(new Date(PROGRAM_START));
const PROGRAM_END_DATE = normalizeDate(new Date(PROGRAM_END));

// ------------------------------
// ARM EMOJI
// ------------------------------
function getArmEmoji(score: number | null): string {
  if (score === null) return "❓";
  if (score <= 3) return "💀";
  if (score <= 6) return "😐";
  if (score <= 8) return "🙂";
  return "💪";
}

// ------------------------------
// MAIN COMPONENT
// ------------------------------

export default function TodayPage() {
  const router = useRouter();
  const today = normalizeDate(new Date());

  const [user, setUser] = useState<any>(null);

  const [baseDate, setBaseDate] = useState<Date>(() => {
    let d = today;
    if (d < PROGRAM_START_DATE) d = PROGRAM_START_DATE;
    if (d > PROGRAM_END_DATE) d = PROGRAM_END_DATE;
    return d;
  });

  const [offset, setOffset] = useState(0);

  const [saveStatus, setSaveStatus] = useState<
    null | "saving" | "saved" | "error"
  >(null);
  const [saveMessage, setSaveMessage] = useState<string>("");

  // read ?date= from URL on client only
  useEffect(() => {
    if (typeof window === "undefined") return;
    const params = new URLSearchParams(window.location.search);
    const param = params.get("date");
    if (!param) return;

    const parsed = normalizeDate(new Date(param));
    if (!isNaN(parsed.getTime())) {
      let d = parsed;
      if (d < PROGRAM_START_DATE) d = PROGRAM_START_DATE;
      if (d > PROGRAM_END_DATE) d = PROGRAM_END_DATE;
      setBaseDate(d);
      setOffset(0);
    }
  }, []);

  // current date = baseDate + offset
  const viewDate = useMemo(() => {
    const d = new Date(baseDate);
    d.setDate(baseDate.getDate() + offset);
    return normalizeDate(d);
  }, [baseDate, offset]);

  const canGoPrev = viewDate > PROGRAM_START_DATE;
  const canGoNext = viewDate < PROGRAM_END_DATE;

  const dateKey = toDateKey(viewDate);
  const prettyDate = formatPrettyDate(viewDate);

  const diffDays = (viewDate.getTime() - today.getTime()) / 86400000;

  const dayLabel =
    diffDays === 0 ? "TODAY" : diffDays === -1 ? "YESTERDAY" : "";

  const programForDay: DayProgram = getProgramForDate(dateKey);

  const isFlatRequired = !!programForDay.flatGround;
  const rawBullpen = (programForDay.bullpen ?? "").trim();
  const isPenRequired = rawBullpen.length > 0;

  const [timeThrown, setTimeThrown] = useState("");
  const [distanceThrown, setDistanceThrown] = useState("");
  const [flatGroundDone, setFlatGroundDone] = useState(isFlatRequired);
  const [bullpenDone, setBullpenDone] = useState(isPenRequired);
  const [armFeeling, setArmFeeling] = useState("8");
  const [notes, setNotes] = useState("");

  // reset form when date or required-ness changes
  useEffect(() => {
    setTimeThrown("");
    setDistanceThrown("");
    setFlatGroundDone(isFlatRequired);
    setBullpenDone(isPenRequired);
    setArmFeeling("8");
    setNotes("");
    setSaveStatus(null);
    setSaveMessage("");
  }, [dateKey, isFlatRequired, isPenRequired]);

  // Load existing log for this user + date and prefill
  useEffect(() => {
    let cancelled = false;

    async function loadExistingLog() {
      if (!supabase) return;

      const {
        data: { user },
        error: userError,
      } = await supabase.auth.getUser();

      if (userError || !user) {
        setUser(null);
        return;
      }

      setUser(user);

      // Ensure profile row exists
      const defaultName =
        user.user_metadata?.full_name ||
        user.email?.split("@")[0] ||
        "PLAYER";

      await supabase.from("profiles").upsert(
        {
          id: user.id,
          display_name: defaultName,
          role: "player",
        },
        {
          onConflict: "id",
        }
      );

      const { data, error } = await supabase
        .from("daily_logs")
        .select(
          "throwing_time, throwing_distance, flat_ground, bullpen, arm_feeling, notes"
        )
        .eq("user_id", user.id)
        .eq("log_date", dateKey)
        .maybeSingle();

      if (cancelled || error || !data) return;

      setTimeThrown(
        data.throwing_time !== null ? String(data.throwing_time) : ""
      );
      setDistanceThrown(
        data.throwing_distance !== null ? String(data.throwing_distance) : ""
      );
      setFlatGroundDone(
        typeof data.flat_ground === "boolean"
          ? data.flat_ground
          : isFlatRequired
      );
      setBullpenDone(
        typeof data.bullpen === "boolean" ? data.bullpen : isPenRequired
      );
      setArmFeeling(
        data.arm_feeling !== null ? String(data.arm_feeling) : "8"
      );
      setNotes(data.notes ?? "");
      setSaveStatus("saved");
      setSaveMessage("Previously saved for this day.");
    }

    loadExistingLog();

    return () => {
      cancelled = true;
    };
  }, [dateKey, isFlatRequired, isPenRequired]);

  const touchStartX = useRef<number | null>(null);

  function goPrevDay() {
    if (canGoPrev) setOffset((o) => o - 1);
  }

  function goNextDay() {
    if (canGoNext) setOffset((o) => o + 1);
  }

  function handleTouchStart(e: TouchEvent<HTMLDivElement>) {
    touchStartX.current = e.touches[0].clientX;
  }

  function handleTouchEnd(e: TouchEvent<HTMLDivElement>) {
    if (touchStartX.current === null) return;
    const dx = e.changedTouches[0].clientX - touchStartX.current;
    if (dx > 50) goPrevDay();
    else if (dx < -50) goNextDay();
    touchStartX.current = null;
  }

  const armScoreNum = armFeeling ? Number(armFeeling) : null;

  async function handleSave() {
    const {
      data: { user },
      error: userErr,
    } = await supabase.auth.getUser();

    if (userErr || !user) {
      alert("Log in again.");
      router.push("/login");
      return;
    }

    setSaveStatus("saving");
    setSaveMessage("");

    const throwingTimeNum = timeThrown.trim() ? Number(timeThrown) : null;
    const throwingDistanceNum = distanceThrown.trim()
      ? Number(distanceThrown)
      : null;
    const armFeelingNum = armFeeling.trim() ? Number(armFeeling) : null;

    const { error } = await supabase.from("daily_logs").upsert(
      {
        user_id: user.id,
        log_date: dateKey,
        throwing_time: throwingTimeNum,
        throwing_distance: throwingDistanceNum,
        flat_ground: flatGroundDone,
        bullpen: bullpenDone,
        arm_feeling: armFeelingNum,
        notes,
      },
      {
        onConflict: "user_id,log_date",
      }
    );

    if (error) {
      console.error(error);
      setSaveStatus("error");
      setSaveMessage("Save failed. Check connection and try again.");
      return;
    }

    const now = new Date();
    const timeString = now.toLocaleTimeString("en-US", {
      hour: "numeric",
      minute: "2-digit",
    });

    setSaveStatus("saved");
    setSaveMessage(
      `Saved at ${timeString}${
        user.email ? ` as ${user.email.split("@")[0]}` : ""
      }`
    );
  }

  // ------------------------------
  // RENDER
  // ------------------------------
  return (
    <div
      className={`${bebas.className} relative min-h-screen bg-slate-950 text-slate-50 flex flex-col items-center text-center`}
      onTouchStart={handleTouchStart}
      onTouchEnd={handleTouchEnd}
    >
      {/* LOGIN / PROFILE INDICATOR (tiny, top-right) */}
      <div className="absolute top-3 right-4 flex items-center gap-1 text-[10px] tracking-[0.18em]">
        {user ? (
          <button
            type="button"
            onClick={() => router.push("/profile")}
            className="flex items-center gap-1 text-slate-400"
          >
            <span className="h-2 w-2 rounded-full bg-emerald-400" />
            <span className="underline">
              {user.email?.slice(0, 4).toLowerCase()}…
            </span>
          </button>
        ) : (
          <button
            type="button"
            onClick={() => router.push("/login")}
            className="flex items-center gap-1 text-red-400"
          >
            <span className="h-2 w-2 rounded-full bg-red-500" />
            <span className="underline">LOGIN</span>
          </button>
        )}
      </div>

      <main className="w-full max-w-md px-4 pb-24 pt-6 flex-1 space-y-4 uppercase">
        {/* HEADER */}
        <header className="flex flex-col items-center gap-2">
          <p className="text-[11px] tracking-[0.32em] text-slate-400">
            WINTER 94
          </p>
          <h1 className="text-4xl tracking-[0.22em]">TODAY</h1>

          <div className="mt-2 flex items-center justify-center gap-8">
            <button
              onClick={goPrevDay}
              disabled={!canGoPrev}
              className={`h-9 w-9 flex items-center justify-center rounded-full border text-xl ${
                canGoPrev
                  ? "border-slate-700 text-slate-200"
                  : "border-slate-800 text-slate-600"
              }`}
            >
              ◀
            </button>

            <div className="flex flex-col items-center">
              <p className="text-sm tracking-[0.22em] text-slate-50">
                {prettyDate}
              </p>
              <p className="text-[10px] tracking-[0.3em] text-slate-500">
                SWIPE ◀▶ TO CHANGE DAY
              </p>
              {dayLabel && (
                <p className="mt-1 text-[10px] text-emerald-400 tracking-[0.22em]">
                  {dayLabel}
                </p>
              )}
            </div>

            <button
              onClick={goNextDay}
              disabled={!canGoNext}
              className={`h-9 w-9 flex items-center justify-center rounded-full border text-xl ${
                canGoNext
                  ? "border-slate-700 text-slate-200"
                  : "border-slate-800 text-slate-600"
              }`}
            >
              ▶
            </button>
          </div>
        </header>

        {/* REQUIRED TODAY */}
        <section className="rounded-3xl border border-slate-800 bg-slate-900/90 px-4 py-4 space-y-3">
          <p className="text-[11px] tracking-[0.26em] text-slate-300">
            REQUIRED TODAY
          </p>

          <div className="flex flex-col items-center gap-1">
            <p className="text-5xl tracking-tight text-slate-50">
              {programForDay.throwingDistance || "OFF"}
            </p>
            <p className="text-base tracking-[0.18em] text-slate-300">
              {programForDay.throwingTime ||
                (programForDay.throwingDistance ? "" : "REST DAY")}
            </p>
          </div>

          <div className="mt-2 grid grid-cols-2 gap-2 text-[11px] tracking-[0.18em]">
            <div className="rounded-2xl bg-slate-950/60 border border-slate-800 px-3 py-2 flex flex-col items-center">
              <span className="text-slate-400">FLAT GROUND</span>
              <span className="mt-1 text-slate-100">
                {isFlatRequired ? "YES" : "NO"}
              </span>
            </div>
            <div className="rounded-2xl bg-slate-950/60 border border-slate-800 px-3 py-2 flex flex-col items-center">
              <span className="text-slate-400">BULLPEN</span>
              <span className="mt-1 text-slate-100">
                {isPenRequired ? "YES" : "NO"}
              </span>
            </div>
          </div>
        </section>

        {/* LOG YOUR WORK */}
        <section className="rounded-3xl border border-slate-800 bg-slate-900 px-4 py-4 space-y-3">
          <div className="flex items-center justify-between">
            <p className="text-[11px] tracking-[0.26em] text-emerald-400">
              LOG YOUR WORK
            </p>
          </div>

          {/* THROWING INPUTS */}
          <div className="grid grid-cols-2 gap-3">
            <div className="flex flex-col items-center">
              <p className="text-[10px] tracking-[0.22em] text-slate-400">
                TIME (MIN)
              </p>
              <input
                type="number"
                placeholder="0"
                value={timeThrown}
                onChange={(e) => setTimeThrown(e.target.value)}
                className="mt-2 w-full bg-slate-950 border border-slate-700 rounded-2xl px-3 py-3 text-4xl font-bold text-center focus:border-emerald-500 outline-none transition"
              />
            </div>

            <div className="flex flex-col items-center">
              <p className="text-[10px] tracking-[0.22em] text-slate-400">
                DISTANCE (FT)
              </p>
              <input
                type="number"
                placeholder="0"
                value={distanceThrown}
                onChange={(e) => setDistanceThrown(e.target.value)}
                className="mt-2 w-full bg-slate-950 border border-slate-700 rounded-2xl px-3 py-3 text-4xl font-bold text-center focus:border-emerald-500 outline-none transition"
              />
            </div>
          </div>

          {/* SESSION TYPE TOGGLES */}
          <div className="mt-4 grid grid-cols-2 gap-3 text-left">
            <button
              type="button"
              onClick={() =>
                isFlatRequired && setFlatGroundDone(!flatGroundDone)
              }
              className={`rounded-2xl px-3 py-3 border text-[11px] tracking-[0.2em] transition ${
                flatGroundDone
                  ? "border-emerald-400 bg-emerald-500/10 text-emerald-200"
                  : isFlatRequired
                  ? "border-slate-700 bg-slate-950/70 text-slate-200"
                  : "border-slate-800 bg-slate-950/40 text-slate-500"
              }`}
            >
              <p>FLAT GROUND</p>
              <p className="mt-1 text-sm">
                {flatGroundDone
                  ? "DONE"
                  : isFlatRequired
                  ? "NOT DONE"
                  : "NOT SCHEDULED"}
              </p>
            </button>

            <button
              type="button"
              onClick={() => isPenRequired && setBullpenDone(!bullpenDone)}
              className={`rounded-2xl px-3 py-3 border text-[11px] tracking-[0.2em] transition ${
                bullpenDone
                  ? "border-emerald-400 bg-emerald-500/10 text-emerald-200"
                  : isPenRequired
                  ? "border-slate-700 bg-slate-950/70 text-slate-200"
                  : "border-slate-800 bg-slate-950/40 text-slate-500"
              }`}
            >
              <p>BULLPEN</p>
              <p className="mt-1 text-sm">
                {isPenRequired
                  ? bullpenDone
                    ? "DONE"
                    : "NOT DONE"
                  : "NOT SCHEDULED"}
              </p>
            </button>
          </div>
        </section>

        {/* ARM FEEL */}
        <section className="rounded-3xl border border-slate-800 bg-slate-900 px-4 py-4">
          <p className="text-[11px] tracking-[0.26em] text-emerald-400 mb-1">
            ARM FEEL
          </p>
          <p className="text-[10px] tracking-[0.22em] text-slate-400 mb-3">
            HIGHER IS BETTER • TARGET 7–9/10 ON MOST DAYS
          </p>

          <div className="relative mb-3">
            <div className="absolute inset-x-2 top-1/2 h-[4px] -translate-y-1/2 rounded-full bg-gradient-to-r from-red-500 via-yellow-400 to-emerald-400 opacity-60" />
            <input
              type="range"
              min="1"
              max="10"
              value={armFeeling}
              onChange={(e) => setArmFeeling(e.target.value)}
              className="relative w-full appearance-none bg-transparent accent-emerald-500"
            />
          </div>

          <p className="text-xl tracking-[0.2em] text-slate-200 flex items-center justify-center gap-2">
            TODAY:
            <span className="text-3xl text-emerald-400">
              {armScoreNum !== null ? `${armScoreNum}/10` : "—"}
            </span>
            <span className="text-3xl">{getArmEmoji(armScoreNum)}</span>
          </p>
        </section>

        {/* NOTES */}
        <section className="rounded-3xl border border-slate-800 bg-slate-900 px-3 py-3 text-left">
          <p className="text-[11px] tracking-[0.22em] text-slate-400 mb-2">
            NOTES
          </p>
          <textarea
            value={notes}
            onChange={(e) => setNotes(e.target.value)}
            placeholder="Mechanics, fatigue, how it felt…"
            className="w-full bg-slate-950 rounded-xl px-3 py-2 text-base text-slate-200 border border-slate-700 focus:border-emerald-400 outline-none resize-none normal-case"
            rows={3}
          />
        </section>

        {/* SAVE */}
        <div className="space-y-2">
          <button
            onClick={handleSave}
            className="w-full rounded-2xl bg-emerald-500 py-5 text-xl tracking-[0.26em] font-bold text-black shadow-lg shadow-emerald-500/40 hover:bg-emerald-400"
          >
            {saveStatus === "saving" ? "SAVING…" : "SAVE DAY"}
          </button>
          <div className="min-h-[16px]">
            {saveStatus === "saved" && (
              <p className="text-[11px] text-emerald-400">{saveMessage}</p>
            )}
            {saveStatus === "error" && (
              <p className="text-[11px] text-red-400">{saveMessage}</p>
            )}
            {saveStatus === "saving" && (
              <p className="text-[11px] text-slate-400">Saving…</p>
            )}
          </div>
        </div>
      </main>

      <BottomNav />
    </div>
  );
}
