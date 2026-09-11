'use client';

import { useState } from 'react';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { mailApi } from '@/lib/api';

interface MailComposeProps {
  onClose: () => void;
  onSuccess?: () => void;
}

export default function MailCompose({ onClose, onSuccess }: MailComposeProps) {
  const [to, setTo] = useState('');
  const [cc, setCc] = useState('');
  const [subject, setSubject] = useState('');
  const [body, setBody] = useState('');
  const [showCc, setShowCc] = useState(false);

  const queryClient = useQueryClient();

  const sendMutation = useMutation({
    mutationFn: mailApi.sendEmail,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['inbox'] });
      queryClient.invalidateQueries({ queryKey: ['sent'] });
      onSuccess?.();
      onClose();
    }
  });

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();

    const toList = to.split(',').map((email) => email.trim()).filter(Boolean);
    const ccList = cc ? cc.split(',').map((email) => email.trim()).filter(Boolean) : undefined;

    if (toList.length === 0) {
      alert('Veuillez entrer au moins un destinataire');
      return;
    }

    sendMutation.mutate({
      to: toList,
      cc: ccList,
      subject,
      body: body.replace(/\n/g, '<br>')
    });
  };

  return (
    <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50">
      <div className="bg-white rounded-xl shadow-xl w-full max-w-2xl max-h-[90vh] flex flex-col">
        <div className="flex items-center justify-between p-4 border-b border-hedwige-100">
          <h2 className="text-xl font-semibold text-hedwige-900">Nouveau message</h2>
          <button
            onClick={onClose}
            className="text-hedwige-500 hover:text-hedwige-700 text-2xl"
          >
            &times;
          </button>
        </div>

        <form onSubmit={handleSubmit} className="flex-1 flex flex-col overflow-hidden">
          <div className="p-4 space-y-3 border-b border-hedwige-100">
            <div className="flex items-center space-x-2">
              <label className="w-12 text-hedwige-600 text-sm">A:</label>
              <input
                type="text"
                value={to}
                onChange={(e) => setTo(e.target.value)}
                placeholder="email@exemple.com, autre@exemple.com"
                className="input flex-1"
                required
              />
              {!showCc && (
                <button
                  type="button"
                  onClick={() => setShowCc(true)}
                  className="text-hedwige-600 text-sm hover:underline"
                >
                  Cc
                </button>
              )}
            </div>

            {showCc && (
              <div className="flex items-center space-x-2">
                <label className="w-12 text-hedwige-600 text-sm">Cc:</label>
                <input
                  type="text"
                  value={cc}
                  onChange={(e) => setCc(e.target.value)}
                  placeholder="email@exemple.com"
                  className="input flex-1"
                />
              </div>
            )}

            <div className="flex items-center space-x-2">
              <label className="w-12 text-hedwige-600 text-sm">Objet:</label>
              <input
                type="text"
                value={subject}
                onChange={(e) => setSubject(e.target.value)}
                placeholder="Objet du message"
                className="input flex-1"
              />
            </div>
          </div>

          <div className="flex-1 p-4 overflow-auto">
            <textarea
              value={body}
              onChange={(e) => setBody(e.target.value)}
              placeholder="Ecrivez votre message..."
              className="input min-h-[200px] h-full resize-none"
            />
          </div>

          <div className="flex items-center justify-end space-x-3 p-4 border-t border-hedwige-100">
            <button
              type="button"
              onClick={onClose}
              className="btn-secondary"
              disabled={sendMutation.isPending}
            >
              Annuler
            </button>
            <button
              type="submit"
              className="btn-primary"
              disabled={sendMutation.isPending}
            >
              {sendMutation.isPending ? 'Envoi...' : 'Envoyer'}
            </button>
          </div>

          {sendMutation.isError && (
            <div className="px-4 pb-4 text-red-600 text-sm">
              Erreur: {(sendMutation.error as Error).message}
            </div>
          )}
        </form>
      </div>
    </div>
  );
}
