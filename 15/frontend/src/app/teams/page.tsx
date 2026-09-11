'use client';

import { useQuery } from '@tanstack/react-query';
import { authApi } from '@/lib/api';
import TeamMessages from '@/components/TeamMessages';

export default function TeamsPage() {
  const { data: authStatus, isLoading } = useQuery({
    queryKey: ['authStatus'],
    queryFn: authApi.getStatus
  });

  if (isLoading) {
    return (
      <div className="flex items-center justify-center min-h-[60vh]">
        <div className="text-hedwige-600">Chargement...</div>
      </div>
    );
  }

  if (!authStatus?.authenticated) {
    return (
      <div className="card text-center">
        <p className="text-hedwige-600 mb-4">Connectez-vous pour acceder a Teams</p>
        <a href={authApi.getLoginUrl()} className="btn-primary">
          Se connecter
        </a>
      </div>
    );
  }

  return (
    <div>
      <h1 className="text-2xl font-bold text-hedwige-900 mb-6">Teams</h1>
      <TeamMessages />
    </div>
  );
}
