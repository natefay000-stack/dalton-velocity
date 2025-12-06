import "./globals.css";

export const metadata = {
  title: "Dalton Velocity",
  description: "Winter 94 throwing program for Dalton",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <body className="bg-black text-white font-sans">
        {children}
      </body>
    </html>
  );
}
