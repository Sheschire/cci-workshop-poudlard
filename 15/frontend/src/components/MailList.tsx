'use client';

import { EmailMessage } from '@/lib/api';

interface MailListProps {
  messages: EmailMessage[];
  selectedId?: string;
  onSelect: (message: EmailMessage) => void;
  isLoading?: boolean;
}

export default function MailList({ messages, selectedId, onSelect, isLoading }: MailListProps) {
  if (isLoading) {
    return (
      <div className="space-y-2">
        {[...Array(5)].map((_, i) => (
          <div key={i} className="bg-hedwige-100 animate-pulse h-20 rounded-lg" />
        ))}
      </div>
    );
  }

  if (messages.length === 0) {
    return (
      <div className="text-center py-8 text-hedwige-600">
        Aucun email trouve
      </div>
    );
  }

  const formatDate = (dateString: string) => {
    const date = new Date(dateString);
    const now = new Date();
    const isToday = date.toDateString() === now.toDateString();

    if (isToday) {
      return date.toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' });
    }

    return date.toLocaleDateString('fr-FR', { day: 'numeric', month: 'short' });
  };

  return (
    <div className="space-y-2">
      {messages.map((message) => (
        <button
          key={message.id}
          onClick={() => onSelect(message)}
          className={`w-full text-left p-4 rounded-lg border transition-colors ${
            selectedId === message.id
              ? 'bg-hedwige-100 border-hedwige-300'
              : 'bg-white border-hedwige-100 hover:bg-hedwige-50'
          } ${!message.isRead ? 'font-semibold' : ''}`}
        >
          <div className="flex items-start justify-between">
            <div className="flex-1 min-w-0">
              <div className="flex items-center space-x-2">
                {!message.isRead && (
                  <span className="w-2 h-2 bg-hedwige-600 rounded-full flex-shrink-0" />
                )}
                <span className="text-hedwige-800 truncate">
                  {message.from?.emailAddress?.name || message.from?.emailAddress?.address || 'Inconnu'}
                </span>
              </div>
              <div className="text-hedwige-900 truncate mt-1">
                {message.subject || '(Sans objet)'}
              </div>
              <div className="text-hedwige-500 text-sm truncate mt-1">
                {message.bodyPreview}
              </div>
            </div>
            <div className="text-xs text-hedwige-500 ml-4 flex-shrink-0">
              {formatDate(message.receivedDateTime)}
              {message.hasAttachments && <span className="ml-1">📎</span>}
            </div>
          </div>
        </button>
      ))}
    </div>
  );
}
