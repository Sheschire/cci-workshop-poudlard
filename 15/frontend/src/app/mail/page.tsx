'use client';

import { useState } from 'react';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { mailApi, EmailMessage, authApi } from '@/lib/api';
import MailList from '@/components/MailList';
import MailCompose from '@/components/MailCompose';

type MailView = 'inbox' | 'sent';

export default function MailPage() {
  const [view, setView] = useState<MailView>('inbox');
  const [selectedMessage, setSelectedMessage] = useState<EmailMessage | null>(null);
  const [showCompose, setShowCompose] = useState(false);

  const queryClient = useQueryClient();

  const { data: authStatus } = useQuery({
    queryKey: ['authStatus'],
    queryFn: authApi.getStatus
  });

  const { data: inboxData, isLoading: inboxLoading } = useQuery({
    queryKey: ['inbox'],
    queryFn: () => mailApi.getInbox(),
    enabled: view === 'inbox' && authStatus?.authenticated
  });

  const { data: sentData, isLoading: sentLoading } = useQuery({
    queryKey: ['sent'],
    queryFn: () => mailApi.getSent(),
    enabled: view === 'sent' && authStatus?.authenticated
  });

  const { data: messageDetail, isLoading: messageLoading } = useQuery({
    queryKey: ['message', selectedMessage?.id],
    queryFn: () => mailApi.getMessage(selectedMessage!.id),
    enabled: !!selectedMessage
  });

  const markAsReadMutation = useMutation({
    mutationFn: mailApi.markAsRead,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['inbox'] });
    }
  });

  const deleteMutation = useMutation({
    mutationFn: mailApi.deleteMessage,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['inbox'] });
      queryClient.invalidateQueries({ queryKey: ['sent'] });
      setSelectedMessage(null);
    }
  });

  const handleSelectMessage = (message: EmailMessage) => {
    setSelectedMessage(message);
    if (!message.isRead) {
      markAsReadMutation.mutate(message.id);
    }
  };

  const handleDelete = () => {
    if (selectedMessage && confirm('Supprimer ce message ?')) {
      deleteMutation.mutate(selectedMessage.id);
    }
  };

  if (!authStatus?.authenticated) {
    return (
      <div className="card text-center">
        <p className="text-hedwige-600 mb-4">Connectez-vous pour acceder a vos emails</p>
        <a href={authApi.getLoginUrl()} className="btn-primary">
          Se connecter
        </a>
      </div>
    );
  }

  const messages = view === 'inbox' ? inboxData?.messages : sentData?.messages;
  const isLoading = view === 'inbox' ? inboxLoading : sentLoading;

  return (
    <div className="h-[calc(100vh-200px)]">
      <div className="flex items-center justify-between mb-6">
        <h1 className="text-2xl font-bold text-hedwige-900">Emails</h1>
        <button onClick={() => setShowCompose(true)} className="btn-primary">
          ✉️ Nouveau message
        </button>
      </div>

      <div className="grid grid-cols-12 gap-6 h-full">
        {/* Sidebar */}
        <div className="col-span-4 flex flex-col">
          <div className="flex space-x-2 mb-4">
            <button
              onClick={() => setView('inbox')}
              className={`flex-1 py-2 rounded-lg font-medium transition-colors ${
                view === 'inbox'
                  ? 'bg-hedwige-600 text-white'
                  : 'bg-hedwige-100 text-hedwige-700 hover:bg-hedwige-200'
              }`}
            >
              📥 Boite de reception
            </button>
            <button
              onClick={() => setView('sent')}
              className={`flex-1 py-2 rounded-lg font-medium transition-colors ${
                view === 'sent'
                  ? 'bg-hedwige-600 text-white'
                  : 'bg-hedwige-100 text-hedwige-700 hover:bg-hedwige-200'
              }`}
            >
              📤 Envoyes
            </button>
          </div>

          <div className="flex-1 overflow-auto">
            <MailList
              messages={messages || []}
              selectedId={selectedMessage?.id}
              onSelect={handleSelectMessage}
              isLoading={isLoading}
            />
          </div>
        </div>

        {/* Message Detail */}
        <div className="col-span-8 card overflow-hidden flex flex-col p-0">
          {selectedMessage ? (
            <>
              <div className="p-4 border-b border-hedwige-100 bg-hedwige-50">
                <div className="flex items-start justify-between">
                  <div>
                    <h2 className="text-xl font-semibold text-hedwige-900">
                      {selectedMessage.subject || '(Sans objet)'}
                    </h2>
                    <div className="text-hedwige-600 mt-1">
                      <span className="font-medium">
                        {view === 'inbox' ? 'De: ' : 'A: '}
                      </span>
                      {view === 'inbox'
                        ? selectedMessage.from?.emailAddress?.address
                        : selectedMessage.toRecipients?.[0]?.emailAddress?.address}
                    </div>
                    <div className="text-sm text-hedwige-500 mt-1">
                      {new Date(selectedMessage.receivedDateTime).toLocaleString('fr-FR')}
                    </div>
                  </div>
                  <button
                    onClick={handleDelete}
                    className="text-red-500 hover:text-red-700 p-2"
                    title="Supprimer"
                  >
                    🗑️
                  </button>
                </div>
              </div>
              <div className="flex-1 overflow-auto p-4">
                {messageLoading ? (
                  <div className="text-hedwige-600">Chargement...</div>
                ) : messageDetail?.body ? (
                  <div
                    className="prose max-w-none"
                    dangerouslySetInnerHTML={{ __html: messageDetail.body.content }}
                  />
                ) : (
                  <div className="text-hedwige-600">{selectedMessage.bodyPreview}</div>
                )}
              </div>
            </>
          ) : (
            <div className="flex-1 flex items-center justify-center text-hedwige-600">
              Selectionnez un message pour le lire
            </div>
          )}
        </div>
      </div>

      {showCompose && (
        <MailCompose
          onClose={() => setShowCompose(false)}
          onSuccess={() => {
            setShowCompose(false);
          }}
        />
      )}
    </div>
  );
}
