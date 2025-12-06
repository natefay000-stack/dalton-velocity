"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

function NavIcon({ active, children }: any) {
  return (
    <div className={active ? "text-emerald-400" : "text-slate-500"}>
      {children}
    </div>
  );
}

export default function BottomNav() {
  const pathname = usePathname();

  const navItems = [
    {
      label: "HOME",
      href: "/",
      icon: (
        <svg
          xmlns="http://www.w3.org/2000/svg"
          fill="currentColor"
          viewBox="0 0 24 24"
          className="h-6 w-6"
        >
          <path d="M12 3l9 7h-3v10H6V10H3l9-7z" />
        </svg>
      ),
    },
    {
      label: "TODAY",
      href: "/today",
      icon: (
        <svg
          xmlns="http://www.w3.org/2000/svg"
          fill="currentColor"
          viewBox="0 0 24 24"
          className="h-6 w-6"
        >
          <path d="M9 2h6v2H9V2zM4 6h16v14H4V6zm4 3v2h8V9H8zm0 4v2h5v-2H8z" />
        </svg>
      ),
    },
    {
      label: "SUMMARY",
      href: "/summary",
      icon: (
        <svg
          xmlns="http://www.w3.org/2000/svg"
          fill="currentColor"
          viewBox="0 0 24 24"
          className="h-6 w-6"
        >
          <path d="M4 4h16v2H4V4zm0 7h16v2H4v-2zm0 7h16v2H4v-2z" />
        </svg>
      ),
    },
    {
      label: "CAL",
      href: "/calendar",
      icon: (
        <svg
          xmlns="http://www.w3.org/2000/svg"
          fill="currentColor"
          viewBox="0 0 24 24"
          className="h-6 w-6"
        >
          <path d="M6 2h2v2h8V2h2v2h4v18H2V4h4V2zm16 6H2v12h20V8z" />
        </svg>
      ),
    },
  ];

  return (
    <nav className="fixed bottom-0 left-0 right-0 z-50 bg-slate-900/80 backdrop-blur-md border-t border-slate-800">
      <div className="mx-auto max-w-md flex justify-around py-2 text-xs font-semibold text-slate-400">
        {navItems.map((item) => {
          const active = pathname === item.href;

          return (
            <Link
              key={item.href}
              href={item.href}
              className="flex flex-col items-center gap-1"
            >
              <NavIcon active={active}>{item.icon}</NavIcon>
              <span
                className={`tracking-wide ${
                  active ? "text-emerald-400" : "text-slate-500"
                }`}
              >
                {item.label}
              </span>
            </Link>
          );
        })}
      </div>
    </nav>
  );
}
