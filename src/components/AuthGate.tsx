"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { supabase } from "@/lib/supabase/client";

type Props = {
  children: React.ReactNode;
};

export default function AuthGate({ children }: Props) {
  const router = useRouter();
  const [checking, setChecking] = useState(true);
  const [authed, setAuthed] = useState(false);

  useEffect(() => {
    async function check() {
      if (!supabase) {
        // If supabase isn't configured, just show the app (dev mode).
        setAuthed(true);
        setChecking(false);
        return;
      }

      const {
        data: { user },
      } = await supabase.auth.getUser();

      if (!user) {
        router.replace("/login");
      } else {
        setAuthed(true);
      }
      setChecking(false);
    }

    check();
  }, [router]);

  if (checking) {
    return (
      <div className="min-h-screen bg-slate-950 text-slate-100 flex items-center justify-center">
        <p className="text-sm text-slate-400">Checking session…</p>
      </div>
    );
  }

  if (!authed) return null;

  return <>{children}</>;
}
