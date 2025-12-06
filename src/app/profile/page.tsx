"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { supabase } from "@/lib/supabase/client";
import BottomNav from "@/components/BottomNav";
import { Bebas_Neue } from "next/font/google";

const bebas = Bebas_Neue({ subsets: ["latin"], weight: "400" });

type Profile = {
  id: string;
  display_name: string | null;
  full_name: string | null;
  role: string | null;
  grad_year: string | null;
};

export default function ProfilePage() {
  const router = useRouter();

  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [status, setStatus] = useState<string | null>(null);

  const [displayName, setDisplayName] = useState("");
  const [role, setRole] = useState("player");
  const [gradYear, setGradYear] = useState("");

  useEffect(() => {
    let cancelled = false;

    async function load() {
      setLoading(true);
      setError(null);
      setStatus(null);

      const {
        data: { user },
        error: userErr,
      } = await supabase.auth.getUser();

      if (userErr || !user) {
        setError("LOG IN TO EDIT PROFILE.");
        setLoading(false);
        return;
      }

      const { data, error } = await supabase
        .from("profiles")
        .select("id, display_name, full_name, role, grad_year")
        .eq("id", user.id)
        .maybeSingle();

      if (cancelled) return;

      if (error) {
        console.error(error);
        setError("COULD NOT LOAD PROFILE.");
        setLoading(false);
        return;
      }

      const profile = (data || {
        id: user.id,
        display_name:
          user.user_metadata?.full_name ||
          user.email?.split("@")[0] ||
          "",
        full_name: user.user_metadata?.full_name || null,
        role: "player",
        grad_year: null,
      }) as Profile;

      setDisplayName(profile.display_name || "");
      setRole(profile.role || "player");
      setGradYear(profile.grad_year || "");

      setLoading(false);
    }

    load();

    return () => {
      cancelled = true;
    };
  }, []);

  async function handleSave() {
    setSaving(true);
    setError(null);
    setStatus(null);

    const {
      data: { user },
      error: userErr,
    } = await supabase.auth.getUser();

    if (userErr || !user) {
      setError("LOG IN AGAIN.");
      setSaving(false);
      router.push("/login");
      return;
    }

    const { error } = await supabase.from("profiles").upsert(
      {
        id: user.id,
        display_name: displayName.trim() || null,
        full_name: displayName.trim() || null,
        role: role || null,
        grad_year: gradYear.trim() || null,
      },
      {
        onConflict: "id",
      }
    );

    if (error) {
      console.error(error);
      setError("COULD NOT SAVE PROFILE.");
      setSaving(false);
      return;
    }

    setSaving(false);
    setStatus("PROFILE SAVED.");
  }

  return (
    <div
      className={`${bebas.className} min-h-screen bg-slate-950 text-slate-50 flex flex-col items-center text-center uppercase`}
    >
      <main className="w-full max-w-md px-4 pb-24 pt-6 flex-1 space-y-4">
        <header className="flex flex-col items-center gap-1">
          <p className="text-[11px] tracking-[0.32em] text-slate-400">
            WINTER 94
          </p>
          <h1 className="text-4xl tracking-[0.28em]">PROFILE</h1>
          <p className="mt-1 text-[10px] tracking-[0.2em] text-slate-500">
            NAME • ROLE • GRAD YEAR
          </p>
        </header>

        {loading ? (
          <p className="text-[11px] tracking-[0.2em] text-slate-400">
            LOADING…
          </p>
        ) : (
          <>
            {/* NAME */}
            <section className="rounded-3xl border border-slate-800 bg-slate-900 p-4 text-left">
              <p className="text-[11px] tracking-[0.25em] text-slate-400 mb-2">
                NAME
              </p>
              <input
                type="text"
                value={displayName}
                onChange={(e) => setDisplayName(e.target.value)}
                placeholder="DALTON"
                className="w-full bg-slate-950 rounded-2xl px-3 py-2 text-base text-slate-200 border border-slate-700 focus:border-emerald-400 outline-none"
              />
            </section>

            {/* ROLE + GRAD YEAR */}
            <section className="rounded-3xl border border-slate-800 bg-slate-900 p-4 text-left space-y-4">
              <div>
                <p className="text-[11px] tracking-[0.25em] text-slate-400 mb-2">
                  ROLE
                </p>
                <select
                  value={role}
                  onChange={(e) => setRole(e.target.value)}
                  className="w-full bg-slate-950 rounded-2xl px-3 py-2 text-base text-slate-200 border border-slate-700 focus:border-emerald-400 outline-none"
                >
                  <option value="player">PLAYER</option>
                  <option value="pitcher">PITCHER</option>
                  <option value="two-way">TWO-WAY</option>
                  <option value="position">POSITION PLAYER</option>
                  <option value="catcher">CATCHER</option>
                </select>
              </div>

              <div>
                <p className="text-[11px] tracking-[0.25em] text-slate-400 mb-2">
                  GRAD YEAR
                </p>
                <input
                  type="text"
                  value={gradYear}
                  onChange={(e) => setGradYear(e.target.value)}
                  placeholder="2027"
                  className="w-full bg-slate-950 rounded-2xl px-3 py-2 text-base text-slate-200 border border-slate-700 focus:border-emerald-400 outline-none"
                />
              </div>
            </section>

            {/* SAVE BUTTON + STATUS */}
            <div className="space-y-2">
              <button
                onClick={handleSave}
                className="w-full rounded-2xl bg-emerald-500 py-4 text-lg tracking-[0.3em] font-bold text-black shadow-lg shadow-emerald-500/40 hover:bg-emerald-400"
              >
                {saving ? "SAVING…" : "SAVE PROFILE"}
              </button>
              <div className="min-h-[16px]">
                {error && (
                  <p className="text-[11px] text-red-400">{error}</p>
                )}
                {status && !error && (
                  <p className="text-[11px] text-emerald-400">
                    {status}
                  </p>
                )}
              </div>
            </div>
          </>
        )}
      </main>

      <BottomNav />
    </div>
  );
}
