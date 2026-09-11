'use client';

import './globals.css';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { useState } from 'react';
import Navbar from '@/components/Navbar';

export default function RootLayout({
  children
}: {
  children: React.ReactNode;
}) {
  const [queryClient] = useState(
    () =>
      new QueryClient({
        defaultOptions: {
          queries: {
            staleTime: 60 * 1000,
            refetchOnWindowFocus: false
          }
        }
      })
  );

  return (
    <html lang="fr">
      <head>
        <title>Hedwige - Email, OneDrive & Teams</title>
        <meta name="description" content="Manage your Microsoft 365 emails, OneDrive files, and Teams messages" />
      </head>
      <body>
        <QueryClientProvider client={queryClient}>
          <div className="min-h-screen flex flex-col">
            <Navbar />
            <main className="flex-1 container mx-auto px-4 py-8">
              {children}
            </main>
          </div>
        </QueryClientProvider>
      </body>
    </html>
  );
}
