import { GraphService } from './graph';

export interface Team {
  id: string;
  displayName: string;
  description?: string;
  webUrl?: string;
}

export interface Channel {
  id: string;
  displayName: string;
  description?: string;
  membershipType?: string;
}

export interface Chat {
  id: string;
  topic?: string;
  chatType: 'oneOnOne' | 'group' | 'meeting';
  createdDateTime: string;
  lastUpdatedDateTime?: string;
  members?: ChatMember[];
}

export interface ChatMember {
  id: string;
  displayName: string;
  email?: string;
}

export interface ChatMessage {
  id: string;
  createdDateTime: string;
  body: {
    contentType: string;
    content: string;
  };
  from?: {
    user?: {
      id: string;
      displayName: string;
    };
  };
  attachments?: Array<{
    id: string;
    contentType: string;
    name: string;
  }>;
}

export class TeamsService {
  private graphService: GraphService;

  constructor(accessToken: string) {
    this.graphService = new GraphService(accessToken);
  }

  /**
   * Get all teams the user is a member of
   */
  async getMyTeams(): Promise<Team[]> {
    const response = await this.graphService.get('/me/joinedTeams', {
      $select: 'id,displayName,description,webUrl'
    });
    return response.value;
  }

  /**
   * Get channels for a specific team
   * @param teamId - The team ID
   */
  async getTeamChannels(teamId: string): Promise<Channel[]> {
    const response = await this.graphService.get(`/teams/${teamId}/channels`, {
      $select: 'id,displayName,description,membershipType'
    });
    return response.value;
  }

  /**
   * Get messages from a channel
   * @param teamId - The team ID
   * @param channelId - The channel ID
   * @param top - Number of messages to retrieve
   */
  async getChannelMessages(teamId: string, channelId: string, top: number = 50): Promise<ChatMessage[]> {
    const response = await this.graphService.get(
      `/teams/${teamId}/channels/${channelId}/messages`,
      { $top: top }
    );
    return response.value;
  }

  /**
   * Get all chats for the current user
   */
  async getMyChats(): Promise<Chat[]> {
    const response = await this.graphService.get('/me/chats', {
      $select: 'id,topic,chatType,createdDateTime,lastUpdatedDateTime'
    });
    return response.value;
  }

  /**
   * Get messages from a specific chat
   * @param chatId - The chat ID
   * @param top - Number of messages to retrieve
   */
  async getChatMessages(chatId: string, top: number = 50): Promise<ChatMessage[]> {
    const response = await this.graphService.get(`/me/chats/${chatId}/messages`, {
      $top: top
    });
    return response.value;
  }

  /**
   * Get members of a chat
   * @param chatId - The chat ID
   */
  async getChatMembers(chatId: string): Promise<ChatMember[]> {
    const response = await this.graphService.get(`/me/chats/${chatId}/members`);
    return response.value.map((member: any) => ({
      id: member.id,
      displayName: member.displayName,
      email: member.email
    }));
  }

  /**
   * Send a message to a chat
   * @param chatId - The chat ID
   * @param content - Message content (HTML supported)
   */
  async sendChatMessage(chatId: string, content: string): Promise<ChatMessage> {
    return this.graphService.post(`/me/chats/${chatId}/messages`, {
      body: {
        contentType: 'html',
        content: content
      }
    });
  }

  /**
   * Get a specific chat by ID with expanded members
   * @param chatId - The chat ID
   */
  async getChat(chatId: string): Promise<Chat> {
    const chat = await this.graphService.get(`/me/chats/${chatId}`, {
      $select: 'id,topic,chatType,createdDateTime,lastUpdatedDateTime'
    });

    // Get members separately
    const members = await this.getChatMembers(chatId);

    return {
      ...chat,
      members
    };
  }
}
