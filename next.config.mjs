import './globals.css';
import Link from 'next/link';

export const metadata = { title: 'Proxmox Cloud Portal', description: 'Self-service cloud portal' };

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body>
        <header>
          <strong>Cloud Portal</strong>
          <nav style={{ display: 'inline', marginLeft: 30 }}>
            <Link href="/">Dashboard</Link>
            <Link href="/vms">Virtual Machines</Link>
          </nav>
        </header>
        <main>{children}</main>
      </body>
    </html>
  );
}
