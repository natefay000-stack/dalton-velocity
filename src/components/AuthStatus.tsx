"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { supabase } from "@/lib/supabase/client";

type SimpleUser = {
  email: string | null;
};

export default function AuthStatus() {
  const [user, setUser] = useState<SimpleUser | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let isMounted = true;

    async function load() {
      const { data } = await supabase.auth.getUser();

      if (!isMounted) return;

      setUser(data.user ? { email: data.user.email ?? null } : null);
      setLoading(false);
    }

    load();

    const {
      data: { subscription },
    } = supabase.auth.onAuthStateChange((_event, session) => {
      if (!isMounted) return;
      setUser(session?.user ? { email: session.user.email ?? null } : null);
    });

    return () => {
      isMounted = false;
      subscription.unsubscribe();
    };
  }, []);

  if (loading) {
    return (
      <div className="inline-flex h-9 items-center rounded-full border border-slate-700 px-3 text-xs text-slate-500">
        …
      </div>
    );
  }

  // NOT LOGGED IN → big obvious LOGIN pill (red)
  if (!user) {
    return (
      <Link
        href="/login"
        className="inline-flex h-9 items-center rounded-full bg-red-600 px-4 text-xs font-semibold text-white shadow-sm hover:bg-red-500 border border-red-400"
      >
        LOGIN
      </Link>
    );
  }

  // LOGGED IN → show initial + small text
  const initial = user.email?.[0]?.toUpperCase() ?? "U";

  return (
    <div className="inline-flex items-center gap-2 rounded-full border border-emerald-500/70 bg-emerald-500/10 px-3 py-1">
      <div className="flex h-6 w-6 items-center justify-center rounded-full bg-emerald-500 text-xs font-bold text-black">
        {initial}
      </div>
      <div className="flex flex-col">
        <span className="text-[10px] uppercase tracking-[0.16em] text-emerald-300">
          LOGGED IN
        </span>
        <span className="text-[11px] text-slate-100">
          {user.email?.split("@")[0] ?? "Player"}
        </span>
      </div>
    </div>
  );
}
