"use client";

import { supabase } from "@/lib/supabase/client";
import BottomNav from "@/components/BottomNav";
import { useRouter, useSearchParams } from "next/navigation";
import { useEffect, useMemo, useState } from "react";

// Define the shape of each day's program
interface DayProgram {
  throwingTime: string;
  throwingDistance: string;
  flatGround: string;
  bullpen: string;
}

// Hard-coded program from your Excel (add all 89 days later)
const programMap: Record<string, DayProgram> = {
  "2025-12-01": {
    throwingTime: "10 minutes",
    throwingDistance: "75 ft",
    flatGround: "15 Pitches (all fastballs)",
    bullpen: "",
  },
  "2025-12-02": {
    throwingTime: "10 minutes",
    throwingDistance: "75 ft",
    flatGround: "15 Pitches (all fastballs)",
    bullpen: "",
  },
  "2025-12-03": {
    throwingTime: "",
    throwingDistance: "",
    flatGround: "",
    bullpen: "",
  }, // OFF
  "2025-12-04": {
    throwingTime: "10 minutes",
    throwingDistance: "75 ft",
    flatGround: "15 Pitches (all fastballs)",
    bullpen: "",
  },
  "2025-12-05": {
    throwingTime: "10 minutes",
    throwingDistance: "75 ft",
    flatGround: "15 Pitches (all fastballs)",
    bullpen: "",
  },
  // Add the rest from your Excel here
  "2026-01-19": {
    throwingTime: "25 minutes +",
    throwingDistance: "300+ ft",
    flatGround: "",
    bullpen: "60 Pitches (25 FB, 15 CH, 15 CU; 1-2 Hitters)",
  },
};

function normalizeDate(d: Date) {
  const nd = new Date(d);
  nd.setHours(0, 0, 0, 0);
  return nd;
}

export default function TodayClient() {
  const router = useRouter();
  const searchParams = useSearchParams();

  // If ?date=YYYY-MM-DD is provided (from calendar), use that as the base date.
  const [baseDate] = useState(() => {
    const param = searchParams.get("date");
    if (param) {
      const parsed = new Date(param);
      if (!Number.isNaN(parsed.getTime())) {
        return normalizeDate(parsed);
      }
    }
    return normalizeDate(new Date());
  });

  // Offset in days from baseDate: 0 = baseDate, -1 = day before, +1 = day after (up to today)
  const [offset, setOffset] = useState(0);

  const viewDate = useMemo(() => {
    const d = new Date(baseDate);
    d.setDate(baseDate.getDate() + offset);
    return d;
  }, [baseDate, offset]);

  const today = normalizeDate(new Date());
  const dateKey = viewDate.toISOString().split("T")[0]; // YYYY-MM-DD

  // Pretty date like "MONDAY DEC 1"
  const weekday = viewDate
    .toLocaleDateString("en-US", { weekday: "long" })
    .toUpperCase();
  const month = viewDate
    .toLocaleDateString("en-US", { month: "short" })
    .toUpperCase();
  const dayNumber = viewDate.getDate();
  const prettyDate = `${weekday} ${month} ${dayNumber}`;

  const todayProgram: DayProgram =
    programMap[dateKey] || {
      throwingTime: "OFF",
      throwingDistance: "",
      flatGround: "",
      bullpen: "",
    };

  const isFlatRequired = !!todayProgram.flatGround;
  const isPenRequired = !!todayProgram.bullpen;

  const [timeThrown, setTimeThrown] = useState("");
  const [distanceThrown, setDistanceThrown] = useState("");
  const [flatGroundDone, setFlatGroundDone] = useState(isFlatRequired);
  const [bullpenDone, setBullpenDone] = useState(isPenRequired);
  const [armFeeling, setArmFeeling] = useState("8");
  const [notes, setNotes] = useState("");

  // When you change days, reset inputs + defaults based on that day's program
  useEffect(() => {
    setTimeThrown("");
    setDistanceThrown("");
    setArmFeeling("8");
    setNotes("");
    setFlatGroundDone(isFlatRequired);
    setBullpenDone(isPenRequired);
  }, [dateKey, isFlatRequired, isPenRequired]);

  // Can we go forward one day? (never past real TODAY)
  const canGoNext = useMemo(() => {
    const target = new Date(baseDate);
    target.setDate(baseDate.getDate() + offset + 1);
    return normalizeDate(target) <= today;
  }, [baseDate, offset, today]);

  // Label like TODAY / YESTERDAY based on real date, not offset
  const dayLabel = useMemo(() => {
    const diffMs = normalizeDate(viewDate).getTime() - today.getTime();
    const diffDays = Math.round(diffMs / (1000 * 60 * 60 * 24));
    if (diffDays === 0) return "TODAY";
    if (diffDays === -1) return "YESTERDAY";
    return "";
  }, [viewDate, today]);

  // 🔑 save function that ties the log to the logged-in user
  const handleSave = async () => {
    if (!supabase) {
      alert("Supabase is not configured yet. Ask Dad to add the env vars 🤓");
      return;
    }

    // 1️⃣ who is logged in?
    const {
      data: { user },
      error: userError,
    } = await supabase.auth.getUser();

    if (userError) {
      console.error(userError);
      alert("Could not get current user. Try logging in again.");
      return;
    }

    if (!user) {
      alert("You must be logged in to save this session.");
      router.push("/login");
      return;
    }

    // 2️⃣ clean up numbers
    const throwingTimeNum =
      timeThrown.trim() === "" ? null : Number(timeThrown);
    const throwingDistanceNum =
      distanceThrown.trim() === "" ? null : Number(distanceThrown);
    const armFeelingNum =
      armFeeling.trim() === "" ? null : Number(armFeeling);

    // 3️⃣ save (or update) this user's log for this date
    const { error } = await supabase.from("daily_logs").upsert(
      {
        log_date: dateKey,
        user_id: user.id, // tie this row to Dalton / buddy / whoever is logged in
        throwing_time: throwingTimeNum,
        throwing_distance: throwingDistanceNum,
        flat_ground: flatGroundDone,
        bullpen: bullpenDone,
        arm_feeling: armFeelingNum,
        notes,
      },
      {
        onConflict: "log_date,user_id", // requires a unique index on (log_date, user_id)
      }
    );

    if (error) {
      console.error("Error saving log:", error);
      alert("There was a problem saving. Try again.");
      return;
    }

    alert("THROW SAVED!");
    router.push("/");
  };

  return (
    <div
      className="min-h-screen bg-black text-white flex flex-col uppercase"
      style={{
        fontFamily:
          '"Inter", system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif',
      }}
    >
      <main className="w-full max-w-md mx-auto px-4 pb-24 pt-6 flex-1">
        {/* HEADER */}
        <header className="mb-4 text-center">
          <p className="text-[11px] tracking-[0.25em] text-gray-500">
            WINTER 94
          </p>
          <h1 className="mt-1 text-2xl font-black tracking-wide">
            LOG SESSION
          </h1>
        </header>

        {/* DAY NAVIGATION */}
        <div className="flex items-center justify-between mb-4">
          <button
            onClick={() => setOffset(offset - 1)}
            className="px-3 py-1 rounded-full border border-gray-700 text-[11px] tracking-[0.2em] text-gray-300 hover:bg-gray-900 active:scale-[0.97] transition"
          >
            ◀ PREV
          </button>

          <div className="text-center">
            <p className="text-sm font-semibold tracking-[0.18em]">
              {prettyDate}
            </p>
            {dayLabel && (
              <p className="text-[10px] tracking-[0.28em] text-gray-500 mt-1">
                {dayLabel}
              </p>
            )}
          </div>

          <button
            onClick={() => canGoNext && setOffset(offset + 1)}
            disabled={!canGoNext}
            className={`px-3 py-1 rounded-full border text-[11px] tracking-[0.2em] transition ${
              !canGoNext
                ? "border-gray-800 text-gray-700 cursor-not-allowed"
                : "border-gray-700 text-gray-300 hover:bg-gray-900 active:scale-[0.97]"
            }`}
          >
            NEXT ▶
          </button>
        </div>

        {/* REQUIRED TODAY CARD */}
        <section className="mt-2 mb-6 rounded-3xl bg-[#101010] border border-slate-800 p-6 text-center shadow-[0_18px_40px_rgba(0,0,0,0.85)]">
          <p className="text-[11px] tracking-[0.25em] text-white/60 mb-3">
            REQUIRED TODAY
          </p>
          <p className="text-4xl font-black tracking-tight">
            {todayProgram.throwingDistance || "OFF"}
          </p>
          <p className="text-xl mt-1 tracking-[0.2em] text-gray-300">
            {todayProgram.throwingTime ||
              (todayProgram.throwingDistance ? "" : "REST")}
          </p>
          {todayProgram.flatGround && (
            <p className="text-emerald-400 text-sm mt-3 tracking-[0.18em]">
              {todayProgram.flatGround}
            </p>
          )}
          {todayProgram.bullpen && (
            <p className="text-emerald-400 text-sm mt-2 tracking-[0.18em]">
              {todayProgram.bullpen}
            </p>
          )}
        </section>

        <div className="space-y-5">
          {/* TIME + DISTANCE INPUTS */}
          <div className="grid grid-cols-2 gap-4">
            <div className="rounded-2xl bg-[#111111] border border-slate-800 p-4 text-center">
              <p className="text-[10px] tracking-[0.2em] text-gray-400 mb-2 font-semibold">
                TIME (MIN)
              </p>
              <input
                type="number"
                placeholder="0"
                value={timeThrown}
                onChange={(e) => setTimeThrown(e.target.value)}
                className="w-full bg-black/60 rounded-xl px-3 py-2 text-center text-xl font-semibold outline-none border border-slate-700 focus:border-emerald-400 focus:ring-1 focus:ring-emerald-400"
              />
            </div>

            <div className="rounded-2xl bg-[#111111] border border-slate-800 p-4 text-center">
              <p className="text-[10px] tracking-[0.2em] text-gray-400 mb-2 font-semibold">
                DISTANCE (FT)
              </p>
              <input
                type="number"
                placeholder="0"
                value={distanceThrown}
                onChange={(e) => setDistanceThrown(e.target.value)}
                className="w-full bg-black/60 rounded-xl px-3 py-2 text-center text-xl font-semibold outline-none border border-slate-700 focus:border-emerald-400 focus:ring-1 focus:ring-emerald-400"
              />
            </div>
          </div>

          {/* SESSION TYPE BOXES */}
          <div className="grid grid-cols-2 gap-4">
            {/* FLAT GROUND BOX */}
            <button
              type="button"
              onClick={() =>
                isFlatRequired && setFlatGroundDone(!flatGroundDone)
              }
              className={`rounded-2xl border px-4 py-4 text-center transition uppercase ${
                flatGroundDone
                  ? "border-emerald-500 bg-emerald-500/10 text-white"
                  : isFlatRequired
                  ? "border-slate-700 bg-[#111111] text-gray-300"
                  : "border-slate-800 bg-[#080808] text-gray-500"
              }`}
            >
              <p className="text-[10px] tracking-[0.2em] mb-1">
                FLAT GROUND
              </p>
              <p className="text-lg font-semibold">
                {flatGroundDone
                  ? "DONE"
                  : isFlatRequired
                  ? "NOT DONE"
                  : "OFF"}
              </p>
              <p className="mt-1 text-[10px] text-gray-400">
                {isFlatRequired ? "PROGRAM DAY" : "NOT SCHEDULED"}
              </p>
            </button>

            {/* BULLPEN BOX - RED IF NOT BULLPEN DAY */}
            <button
              type="button"
              onClick={() => isPenRequired && setBullpenDone(!bullpenDone)}
              className={`rounded-2xl border px-4 py-4 text-center transition uppercase ${
                isPenRequired
                  ? bullpenDone
                    ? "border-emerald-500 bg-emerald-500/10 text-white"
                    : "border-emerald-500/70 bg-[#111111] text-emerald-200"
                  : "border-red-600 bg-red-900/25 text-red-200"
              }`}
            >
              <p className="text-[10px] tracking-[0.2em] mb-1">BULLPEN</p>
              <p className="text-lg font-semibold">
                {isPenRequired
                  ? bullpenDone
                    ? "DONE"
                    : "NOT DONE"
                  : "OFF DAY"}
              </p>
              <p className="mt-1 text-[10px] text-gray-300">
                {isPenRequired ? "SCHEDULED IN PROGRAM" : "NOT A BULLPEN DAY"}
              </p>
            </button>
          </div>

          {/* ARM FEEL SLIDER */}
          <div className="rounded-2xl bg-[#111111] border border-slate-800 p-5 text-center">
            <p className="text-[10px] tracking-[0.2em] text-gray-400 mb-3">
              ARM FEEL
            </p>
            <input
              type="range"
              min="1"
              max="10"
              value={armFeeling}
              onChange={(e) => setArmFeeling(e.target.value)}
              className="w-full accent-emerald-500"
            />
            <p className="mt-3 text-4xl font-black">
              {armFeeling}
              <span className="text-lg text-gray-400"> / 10</span>
            </p>
          </div>

          {/* NOTES */}
          <div className="rounded-2xl bg-[#111111] border border-slate-800 p-4">
            <p className="text-[10px] tracking-[0.2em] text-gray-400 mb-2">
              NOTES
            </p>
            <textarea
              placeholder="MECHANICS • FATIGUE • HOW IT FELT..."
              value={notes}
              onChange={(e) => setNotes(e.target.value)}
              className="w-full bg-black/60 rounded-xl px-3 py-2 text-sm outline-none border border-slate-700 focus:border-emerald-400 focus:ring-1 focus:ring-emerald-400 resize-none"
              rows={3}
            />
          </div>

          {/* SAVE BUTTON */}
          <button
            onClick={handleSave}
            className="w-full rounded-full bg-emerald-500 py-3 text-sm font-black tracking-[0.2em] text-black hover:bg-emerald-400 transition shadow-md shadow-emerald-500/40"
          >
            SAVE SESSION
          </button>
        </div>
      </main>

      <BottomNav />
    </div>
  );
}
