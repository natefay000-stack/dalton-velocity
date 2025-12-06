"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { supabase } from "@/lib/supabase/client";

type AuthUser =
  | {
      id: string;
      email?: string | null;
      [key: string]: any;
    }
  | null;

export function useRequireAuth() {
  const router = useRouter();
  const [user, setUser] = useState<AuthUser>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let isMounted = true;

    async function check() {
      if (!supabase) {
        // If Supabase isn't configured, don't crash — just stop the loader.
        setLoading(false);
        return;
      }

      const { data, error } = await supabase.auth.getUser();

      if (!isMounted) return;

      if (error || !data?.user) {
        router.replace("/login");
      } else {
        setUser(data.user as AuthUser);
        setLoading(false);
      }
    }

    check();

    return () => {
      isMounted = false;
    };
  }, [router]);

  return { user, loading };
}
