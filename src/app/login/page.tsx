"use client";

import { Suspense, useEffect, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { supabase } from "@/lib/supabase/client";
import { Bebas_Neue } from "next/font/google";
import BottomNav from "@/components/BottomNav";

const bebas = Bebas_Neue({ subsets: ["latin"], weight: "400" });

function LoginContent() {
  const router = useRouter();
  const searchParams = useSearchParams();

  const [email, setEmail] = useState("");
  const [sending, setSending] = useState(false);
  const [message, setMessage] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [processingLink, setProcessingLink] = useState(false);

  // 1) Handle magic-link callback: ?code=... in URL
  useEffect(() => {
    const rawCode = searchParams.get("code");

    if (!rawCode) return;

    const code = rawCode as string; // force non-null for TS

    let cancelled = false;

    async function handleMagicLink() {
      try {
        setProcessingLink(true);
        setMessage("LOGGING YOU IN…");
        setError(null);

        const { data, error } =
          await supabase.auth.exchangeCodeForSession(code);

        if (cancelled) return;

        if (error) {
          console.error("exchangeCodeForSession error:", error);
          setError("LINK EXPIRED OR INVALID. PLEASE REQUEST A NEW ONE.");
          setMessage(null);
          setProcessingLink(false);
          return;
        }

        if (!data.session) {
          setError("COULD NOT CREATE SESSION. TRY AGAIN.");
          setMessage(null);
          setProcessingLink(false);
          return;
        }

        router.replace("/today");
      } catch (err) {
        console.error(err);
        if (!cancelled) {
          setError("SOMETHING WENT WRONG. TRY AGAIN.");
          setMessage(null);
          setProcessingLink(false);
        }
      }
    }

    handleMagicLink();

    return () => {
      cancelled = true;
    };
  }, [searchParams, router]);

  // 2) Send magic link
  async function handleSendLink(e: React.FormEvent) {
    e.preventDefault();
    setSending(true);
    setMessage(null);
    setError(null);

    try {
      if (!email.trim()) {
        setError("ENTER AN EMAIL.");
        setSending(false);
        return;
      }

      const origin =
        typeof window !== "undefined"
          ? window.location.origin
          : "http://localhost:3000";

      const { error } = await supabase.auth.signInWithOtp({
        email: email.trim(),
        options: {
          emailRedirectTo: `${origin}/login`,
        },
      });

      if (error) {
        console.error("signInWithOtp error:", error);
        setError("COULD NOT SEND LINK. CHECK EMAIL AND TRY AGAIN.");
        setSending(false);
        return;
      }

      setMessage("CHECK YOUR EMAIL FOR THE LOGIN LINK.");
      setSending(false);
    } catch (err) {
      console.error(err);
      setError("SOMETHING WENT WRONG. TRY AGAIN.");
      setSending(false);
    }
  }

  // 3) If already logged in, bounce to /today
  useEffect(() => {
    let cancelled = false;

    async function checkSession() {
      const {
        data: { user },
      } = await supabase.auth.getUser();

      if (!cancelled && user) {
        router.replace("/today");
      }
    }

    checkSession();

    return () => {
      cancelled = true;
    };
  }, [router]);

  return (
    <div
      className={`${bebas.className} min-h-screen bg-slate-950 text-slate-50 flex flex-col items-center text-center uppercase`}
    >
      <main className="w-full max-w-md px-4 pb-24 pt-12 flex-1 space-y-6">
        <header className="flex flex-col items-center gap-1">
          <p className="text-[11px] tracking-[0.32em] text-slate-400">
            WINTER 94
          </p>
          <h1 className="text-4xl tracking-[0.28em]">LOGIN</h1>
          <p className="mt-2 text-[10px] tracking-[0.22em] text-slate-500">
            ENTER EMAIL • GET MAGIC LINK • TAP LINK TO LOGIN
          </p>
        </header>

        <section className="rounded-3xl border border-slate-800 bg-slate-900 p-5 text-left">
          <p className="text-[11px] tracking-[0.25em] text-slate-400 mb-2">
            EMAIL
          </p>
          <form onSubmit={handleSendLink} className="space-y-4">
            <input
              type="email"
              placeholder="you@example.com"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              className="w-full bg-slate-950 rounded-2xl px-3 py-3 text-base text-slate-200 border border-slate-700 focus:border-emerald-400 outline-none"
            />

            <button
              type="submit"
              disabled={sending || processingLink}
              className="w-full rounded-2xl bg-emerald-500 py-4 text-lg tracking-[0.3em] font-bold text-black shadow-lg shadow-emerald-500/40 hover:bg-emerald-400 disabled:opacity-60 disabled:cursor-not-allowed"
            >
              {sending ? "SENDING…" : "SEND LOGIN LINK"}
            </button>
          </form>

          <div className="mt-3 min-h-[32px] space-y-1">
            {processingLink && (
              <p className="text-[11px] text-emerald-400">
                PROCESSING LOGIN LINK…
              </p>
            )}
            {message && !processingLink && (
              <p className="text-[11px] text-emerald-400">{message}</p>
            )}
            {error && (
              <p className="text-[11px] text-red-400">{error}</p>
            )}
          </div>
        </section>

        <p className="text-[10px] tracking-[0.18em] text-slate-500">
          IF YOU TAP A LINK AND LAND BACK HERE, IT WILL AUTO-COMPLETE
          LOGIN WHEN THE LINK IS VALID.
        </p>
      </main>

      <BottomNav />
    </div>
  );
}

export default function LoginPage() {
  return (
    <Suspense
      fallback={
        <div className={`${bebas.className} min-h-screen bg-slate-950 text-slate-50 flex items-center justify-center`}>
          <p className="text-[11px] tracking-[0.3em] text-slate-400">
            LOADING LOGIN…
          </p>
        </div>
      }
    >
      <LoginContent />
    </Suspense>
  );
}
