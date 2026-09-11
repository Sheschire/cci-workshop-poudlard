'use client';

import { useQuery } from '@tanstack/react-query';
import { authApi } from '@/lib/api';
import Link from 'next/link';

export default function HomePage() {
  const { data: authStatus, isLoading } = useQuery({
    queryKey: ['authStatus'],
    queryFn: authApi.getStatus
  });

  if (isLoading) {
    return (
      <div className="flex items-center justify-center min-h-[60vh]">
        <div className="text-hedwige-600 text-lg">Chargement...</div>
      </div>
    );
  }

  return (
    <div className="max-w-4xl mx-auto">
      <div className="text-center mb-12">
        <h1 className="text-4xl font-bold text-hedwige-900 mb-4">
          Bienvenue sur Hedwige
        </h1>
        <p className="text-xl text-hedwige-600">
          Votre assistant pour la gestion des emails, fichiers OneDrive et messages Teams
        </p>
      </div>

      {!authStatus?.authenticated ? (
        <div className="card text-center">
          <h2 className="text-2xl font-semibold text-hedwige-800 mb-4">
            Connectez-vous pour commencer
          </h2>
          <p className="text-hedwige-600 mb-6">
            Utilisez votre compte Microsoft (Office 365 / compte etudiant) pour acceder a vos services.
          </p>
          <a href={authApi.getLoginUrl()} className="btn-primary inline-block">
            Se connecter avec Microsoft
          </a>
        </div>
      ) : (
        <>
          <div className="card mb-8">
            <h2 className="text-xl font-semibold text-hedwige-800 mb-2">
              Bonjour, {authStatus.user?.displayName || 'Utilisateur'}
            </h2>
            <p className="text-hedwige-600">
              {authStatus.user?.mail}
            </p>
          </div>

          <div className="grid md:grid-cols-3 gap-6">
            <Link href="/mail" className="card hover:shadow-md transition-shadow group">
              <div className="text-4xl mb-4">📧</div>
              <h3 className="text-xl font-semibold text-hedwige-800 mb-2 group-hover:text-hedwige-600">
                Emails
              </h3>
              <p className="text-hedwige-600">
                Consultez votre boite de reception et envoyez des emails.
              </p>
            </Link>

            <Link href="/onedrive" className="card hover:shadow-md transition-shadow group">
              <div className="text-4xl mb-4">📁</div>
              <h3 className="text-xl font-semibold text-hedwige-800 mb-2 group-hover:text-hedwige-600">
                OneDrive
              </h3>
              <p className="text-hedwige-600">
                Naviguez dans vos fichiers, telechargez et uploadez.
              </p>
            </Link>

            <Link href="/teams" className="card hover:shadow-md transition-shadow group">
              <div className="text-4xl mb-4">💬</div>
              <h3 className="text-xl font-semibold text-hedwige-800 mb-2 group-hover:text-hedwige-600">
                Teams
              </h3>
              <p className="text-hedwige-600">
                Lisez vos conversations et messages Teams.
              </p>
            </Link>
          </div>
        </>
      )}
    </div>
  );
}
