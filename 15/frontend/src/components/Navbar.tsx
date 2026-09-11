'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { useQuery } from '@tanstack/react-query';
import { authApi } from '@/lib/api';

export default function Navbar() {
  const pathname = usePathname();
  const { data: authStatus } = useQuery({
    queryKey: ['authStatus'],
    queryFn: authApi.getStatus
  });

  const isActive = (path: string) => pathname === path;

  const navLinkClass = (path: string) =>
    `nav-link ${isActive(path) ? 'nav-link-active' : ''}`;

  return (
    <nav className="bg-white shadow-sm border-b border-hedwige-100">
      <div className="container mx-auto px-4">
        <div className="flex items-center justify-between h-16">
          <Link href="/" className="flex items-center space-x-2">
            <span className="text-2xl">🦉</span>
            <span className="font-bold text-xl text-hedwige-900">Hedwige</span>
          </Link>

          {authStatus?.authenticated && (
            <div className="flex items-center space-x-2">
              <Link href="/mail" className={navLinkClass('/mail')}>
                📧 Emails
              </Link>
              <Link href="/onedrive" className={navLinkClass('/onedrive')}>
                📁 OneDrive
              </Link>
              <Link href="/teams" className={navLinkClass('/teams')}>
                💬 Teams
              </Link>
            </div>
          )}

          <div className="flex items-center space-x-4">
            {authStatus?.authenticated ? (
              <>
                <span className="text-sm text-hedwige-600">
                  {authStatus.user?.displayName}
                </span>
                <a
                  href={authApi.getLogoutUrl()}
                  className="btn-secondary text-sm"
                >
                  Deconnexion
                </a>
              </>
            ) : (
              <a href={authApi.getLoginUrl()} className="btn-primary text-sm">
                Connexion
              </a>
            )}
          </div>
        </div>
      </div>
    </nav>
  );
}
