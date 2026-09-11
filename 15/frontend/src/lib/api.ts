const API_BASE = process.env.NEXT_PUBLIC_API_URL || 'http://localhost:3001';

interface ApiOptions {
  method?: 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE';
  body?: any;
  headers?: Record<string, string>;
}

async function apiRequest<T>(endpoint: string, options: ApiOptions = {}): Promise<T> {
  const { method = 'GET', body, headers = {} } = options;

  const config: RequestInit = {
    method,
    headers: {
      'Content-Type': 'application/json',
      ...headers
    },
    credentials: 'include'
  };

  if (body) {
    config.body = JSON.stringify(body);
  }

  const response = await fetch(`${API_BASE}${endpoint}`, config);

  if (!response.ok) {
    const error = await response.json().catch(() => ({ message: 'Request failed' }));
    throw new Error(error.message || `API Error: ${response.status}`);
  }

  return response.json();
}

// Auth API
export const authApi = {
  getStatus: () => apiRequest<{ authenticated: boolean; user: any }>('/auth/status'),
  getLoginUrl: () => `${API_BASE}/auth/login`,
  getLogoutUrl: () => `${API_BASE}/auth/logout`
};

// Mail API
export interface EmailMessage {
  id: string;
  subject: string;
  bodyPreview: string;
  body?: { contentType: string; content: string };
  from?: { emailAddress: { name: string; address: string } };
  toRecipients?: Array<{ emailAddress: { name: string; address: string } }>;
  receivedDateTime: string;
  isRead: boolean;
  hasAttachments: boolean;
}

export const mailApi = {
  getInbox: (top = 25, skip = 0) =>
    apiRequest<{ messages: EmailMessage[]; total: number }>(`/mail/inbox?top=${top}&skip=${skip}`),

  getSent: (top = 25) =>
    apiRequest<{ messages: EmailMessage[] }>(`/mail/sent?top=${top}`),

  getMessage: (id: string) =>
    apiRequest<EmailMessage>(`/mail/message/${id}`),

  sendEmail: (data: { to: string[]; subject: string; body: string; cc?: string[]; bcc?: string[] }) =>
    apiRequest<{ success: boolean }>('/mail/send', { method: 'POST', body: data }),

  markAsRead: (id: string) =>
    apiRequest<{ success: boolean }>(`/mail/message/${id}/read`, { method: 'PATCH' }),

  deleteMessage: (id: string) =>
    apiRequest<{ success: boolean }>(`/mail/message/${id}`, { method: 'DELETE' })
};

// OneDrive API
export interface DriveItem {
  id: string;
  name: string;
  size?: number;
  createdDateTime: string;
  lastModifiedDateTime: string;
  webUrl: string;
  folder?: { childCount: number };
  file?: { mimeType: string };
  parentReference?: { id: string; path: string };
}

export const onedriveApi = {
  getFiles: (folderId?: string) =>
    apiRequest<{ items: DriveItem[] }>(`/onedrive/files${folderId ? `?folderId=${folderId}` : ''}`),

  getItem: (id: string) =>
    apiRequest<DriveItem>(`/onedrive/item/${id}`),

  getDownloadUrl: (id: string) =>
    apiRequest<{ downloadUrl: string }>(`/onedrive/download/${id}`),

  uploadFile: (parentId: string, fileName: string, content: string) =>
    apiRequest<{ success: boolean; item: DriveItem }>('/onedrive/upload', {
      method: 'POST',
      body: { parentId, fileName, content }
    }),

  createFolder: (parentId: string, folderName: string) =>
    apiRequest<{ success: boolean; item: DriveItem }>('/onedrive/folder', {
      method: 'POST',
      body: { parentId, folderName }
    }),

  deleteItem: (id: string) =>
    apiRequest<{ success: boolean }>(`/onedrive/item/${id}`, { method: 'DELETE' }),

  search: (query: string) =>
    apiRequest<{ items: DriveItem[] }>(`/onedrive/search?q=${encodeURIComponent(query)}`)
};

// Teams API
export interface Team {
  id: string;
  displayName: string;
  description?: string;
}

export interface Channel {
  id: string;
  displayName: string;
  description?: string;
}

export interface Chat {
  id: string;
  topic?: string;
  chatType: 'oneOnOne' | 'group' | 'meeting';
  createdDateTime: string;
  members?: Array<{ id: string; displayName: string; email?: string }>;
}

export interface ChatMessage {
  id: string;
  createdDateTime: string;
  body: { contentType: string; content: string };
  from?: { user?: { id: string; displayName: string } };
}

export const teamsApi = {
  getTeams: () =>
    apiRequest<{ teams: Team[] }>('/teams'),

  getChannels: (teamId: string) =>
    apiRequest<{ channels: Channel[] }>(`/teams/${teamId}/channels`),

  getChannelMessages: (teamId: string, channelId: string, top = 50) =>
    apiRequest<{ messages: ChatMessage[] }>(`/teams/${teamId}/channels/${channelId}/messages?top=${top}`),

  getChats: () =>
    apiRequest<{ chats: Chat[] }>('/teams/chats'),

  getChat: (chatId: string) =>
    apiRequest<Chat>(`/teams/chats/${chatId}`),

  getChatMessages: (chatId: string, top = 50) =>
    apiRequest<{ messages: ChatMessage[] }>(`/teams/chats/${chatId}/messages?top=${top}`),

  sendChatMessage: (chatId: string, content: string) =>
    apiRequest<{ success: boolean; message: ChatMessage }>(`/teams/chats/${chatId}/messages`, {
      method: 'POST',
      body: { content }
    })
};
