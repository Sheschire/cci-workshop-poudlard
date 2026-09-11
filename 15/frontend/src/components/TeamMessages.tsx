'use client';

import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { teamsApi, Team, Channel, Chat, ChatMessage } from '@/lib/api';

type ViewMode = 'teams' | 'chats';

export default function TeamMessages() {
  const [viewMode, setViewMode] = useState<ViewMode>('chats');
  const [selectedTeam, setSelectedTeam] = useState<Team | null>(null);
  const [selectedChannel, setSelectedChannel] = useState<Channel | null>(null);
  const [selectedChat, setSelectedChat] = useState<Chat | null>(null);

  // Fetch teams
  const { data: teamsData, isLoading: teamsLoading } = useQuery({
    queryKey: ['teams'],
    queryFn: teamsApi.getTeams,
    enabled: viewMode === 'teams'
  });

  // Fetch channels for selected team
  const { data: channelsData, isLoading: channelsLoading } = useQuery({
    queryKey: ['channels', selectedTeam?.id],
    queryFn: () => teamsApi.getChannels(selectedTeam!.id),
    enabled: !!selectedTeam
  });

  // Fetch channel messages
  const { data: channelMessagesData, isLoading: channelMessagesLoading } = useQuery({
    queryKey: ['channelMessages', selectedTeam?.id, selectedChannel?.id],
    queryFn: () => teamsApi.getChannelMessages(selectedTeam!.id, selectedChannel!.id),
    enabled: !!selectedTeam && !!selectedChannel
  });

  // Fetch chats
  const { data: chatsData, isLoading: chatsLoading } = useQuery({
    queryKey: ['chats'],
    queryFn: teamsApi.getChats,
    enabled: viewMode === 'chats'
  });

  // Fetch chat messages
  const { data: chatMessagesData, isLoading: chatMessagesLoading } = useQuery({
    queryKey: ['chatMessages', selectedChat?.id],
    queryFn: () => teamsApi.getChatMessages(selectedChat!.id),
    enabled: !!selectedChat
  });

  const formatDate = (dateString: string) => {
    return new Date(dateString).toLocaleString('fr-FR', {
      day: 'numeric',
      month: 'short',
      hour: '2-digit',
      minute: '2-digit'
    });
  };

  const renderMessage = (message: ChatMessage) => (
    <div key={message.id} className="border-b border-hedwige-50 py-3 last:border-0">
      <div className="flex items-center space-x-2 mb-1">
        <span className="font-medium text-hedwige-800">
          {message.from?.user?.displayName || 'Systeme'}
        </span>
        <span className="text-xs text-hedwige-500">
          {formatDate(message.createdDateTime)}
        </span>
      </div>
      <div
        className="text-hedwige-700 prose prose-sm max-w-none"
        dangerouslySetInnerHTML={{ __html: message.body.content }}
      />
    </div>
  );

  return (
    <div className="grid grid-cols-12 gap-6 h-[calc(100vh-200px)]">
      {/* Sidebar */}
      <div className="col-span-4 card overflow-hidden flex flex-col p-0">
        {/* View Mode Toggle */}
        <div className="flex border-b border-hedwige-100">
          <button
            onClick={() => {
              setViewMode('chats');
              setSelectedTeam(null);
              setSelectedChannel(null);
            }}
            className={`flex-1 py-3 text-center font-medium transition-colors ${
              viewMode === 'chats'
                ? 'bg-hedwige-100 text-hedwige-800'
                : 'text-hedwige-600 hover:bg-hedwige-50'
            }`}
          >
            💬 Conversations
          </button>
          <button
            onClick={() => {
              setViewMode('teams');
              setSelectedChat(null);
            }}
            className={`flex-1 py-3 text-center font-medium transition-colors ${
              viewMode === 'teams'
                ? 'bg-hedwige-100 text-hedwige-800'
                : 'text-hedwige-600 hover:bg-hedwige-50'
            }`}
          >
            👥 Equipes
          </button>
        </div>

        <div className="flex-1 overflow-auto">
          {viewMode === 'chats' && (
            <div className="divide-y divide-hedwige-50">
              {chatsLoading ? (
                <div className="p-4 text-center text-hedwige-600">Chargement...</div>
              ) : chatsData?.chats.length === 0 ? (
                <div className="p-4 text-center text-hedwige-600">Aucune conversation</div>
              ) : (
                chatsData?.chats.map((chat) => (
                  <button
                    key={chat.id}
                    onClick={() => setSelectedChat(chat)}
                    className={`w-full text-left p-4 transition-colors ${
                      selectedChat?.id === chat.id
                        ? 'bg-hedwige-100'
                        : 'hover:bg-hedwige-50'
                    }`}
                  >
                    <div className="font-medium text-hedwige-800">
                      {chat.topic || `${chat.chatType === 'oneOnOne' ? 'Conversation' : 'Groupe'}`}
                    </div>
                    <div className="text-sm text-hedwige-500 mt-1">
                      {chat.chatType === 'oneOnOne' ? '1-1' : chat.chatType === 'group' ? 'Groupe' : 'Reunion'}
                    </div>
                  </button>
                ))
              )}
            </div>
          )}

          {viewMode === 'teams' && !selectedTeam && (
            <div className="divide-y divide-hedwige-50">
              {teamsLoading ? (
                <div className="p-4 text-center text-hedwige-600">Chargement...</div>
              ) : teamsData?.teams.length === 0 ? (
                <div className="p-4 text-center text-hedwige-600">Aucune equipe</div>
              ) : (
                teamsData?.teams.map((team) => (
                  <button
                    key={team.id}
                    onClick={() => setSelectedTeam(team)}
                    className="w-full text-left p-4 hover:bg-hedwige-50 transition-colors"
                  >
                    <div className="font-medium text-hedwige-800">{team.displayName}</div>
                    {team.description && (
                      <div className="text-sm text-hedwige-500 mt-1 line-clamp-2">
                        {team.description}
                      </div>
                    )}
                  </button>
                ))
              )}
            </div>
          )}

          {viewMode === 'teams' && selectedTeam && (
            <div>
              <button
                onClick={() => {
                  setSelectedTeam(null);
                  setSelectedChannel(null);
                }}
                className="w-full text-left p-4 bg-hedwige-50 border-b border-hedwige-100 text-hedwige-600 hover:text-hedwige-800"
              >
                ← Retour aux equipes
              </button>
              <div className="p-4 border-b border-hedwige-100">
                <div className="font-medium text-hedwige-800">{selectedTeam.displayName}</div>
              </div>
              <div className="divide-y divide-hedwige-50">
                {channelsLoading ? (
                  <div className="p-4 text-center text-hedwige-600">Chargement...</div>
                ) : (
                  channelsData?.channels.map((channel) => (
                    <button
                      key={channel.id}
                      onClick={() => setSelectedChannel(channel)}
                      className={`w-full text-left p-4 transition-colors ${
                        selectedChannel?.id === channel.id
                          ? 'bg-hedwige-100'
                          : 'hover:bg-hedwige-50'
                      }`}
                    >
                      <div className="font-medium text-hedwige-800"># {channel.displayName}</div>
                    </button>
                  ))
                )}
              </div>
            </div>
          )}
        </div>
      </div>

      {/* Messages Panel */}
      <div className="col-span-8 card overflow-hidden flex flex-col p-0">
        {viewMode === 'chats' && selectedChat ? (
          <>
            <div className="p-4 border-b border-hedwige-100 bg-hedwige-50">
              <h3 className="font-medium text-hedwige-800">
                {selectedChat.topic || 'Conversation'}
              </h3>
            </div>
            <div className="flex-1 overflow-auto p-4">
              {chatMessagesLoading ? (
                <div className="text-center text-hedwige-600">Chargement des messages...</div>
              ) : chatMessagesData?.messages.length === 0 ? (
                <div className="text-center text-hedwige-600">Aucun message</div>
              ) : (
                chatMessagesData?.messages.map(renderMessage)
              )}
            </div>
          </>
        ) : viewMode === 'teams' && selectedChannel ? (
          <>
            <div className="p-4 border-b border-hedwige-100 bg-hedwige-50">
              <h3 className="font-medium text-hedwige-800">
                {selectedTeam?.displayName} / # {selectedChannel.displayName}
              </h3>
            </div>
            <div className="flex-1 overflow-auto p-4">
              {channelMessagesLoading ? (
                <div className="text-center text-hedwige-600">Chargement des messages...</div>
              ) : channelMessagesData?.messages.length === 0 ? (
                <div className="text-center text-hedwige-600">Aucun message</div>
              ) : (
                channelMessagesData?.messages.map(renderMessage)
              )}
            </div>
          </>
        ) : (
          <div className="flex-1 flex items-center justify-center text-hedwige-600">
            Selectionnez une conversation ou un canal pour voir les messages
          </div>
        )}
      </div>
    </div>
  );
}
