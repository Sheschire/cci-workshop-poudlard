import { TeamsService } from '../src/services/teams.service';
import { GraphService } from '../src/services/graph';

// Mock the GraphService
jest.mock('../src/services/graph');

describe('TeamsService', () => {
  let teamsService: TeamsService;
  let mockGraphService: jest.Mocked<GraphService>;

  beforeEach(() => {
    jest.clearAllMocks();
    teamsService = new TeamsService('mock-access-token');
    mockGraphService = (GraphService as jest.MockedClass<typeof GraphService>).mock.instances[0] as jest.Mocked<GraphService>;
  });

  describe('getMyTeams', () => {
    it('should fetch all teams the user is a member of', async () => {
      const mockTeams = [
        { id: 'team-1', displayName: 'Team Alpha', description: 'First team' },
        { id: 'team-2', displayName: 'Team Beta', description: 'Second team' }
      ];

      mockGraphService.get = jest.fn().mockResolvedValue({ value: mockTeams });

      const result = await teamsService.getMyTeams();

      expect(mockGraphService.get).toHaveBeenCalledWith(
        '/me/joinedTeams',
        expect.any(Object)
      );
      expect(result).toEqual(mockTeams);
    });
  });

  describe('getTeamChannels', () => {
    it('should fetch channels for a specific team', async () => {
      const mockChannels = [
        { id: 'channel-1', displayName: 'General', description: 'General channel' },
        { id: 'channel-2', displayName: 'Development', description: 'Dev channel' }
      ];

      mockGraphService.get = jest.fn().mockResolvedValue({ value: mockChannels });

      const result = await teamsService.getTeamChannels('team-123');

      expect(mockGraphService.get).toHaveBeenCalledWith(
        '/teams/team-123/channels',
        expect.any(Object)
      );
      expect(result).toEqual(mockChannels);
    });
  });

  describe('getChannelMessages', () => {
    it('should fetch messages from a channel', async () => {
      const mockMessages = [
        {
          id: 'msg-1',
          createdDateTime: '2024-01-01T10:00:00Z',
          body: { contentType: 'html', content: '<p>Hello</p>' },
          from: { user: { id: 'user-1', displayName: 'John Doe' } }
        }
      ];

      mockGraphService.get = jest.fn().mockResolvedValue({ value: mockMessages });

      const result = await teamsService.getChannelMessages('team-123', 'channel-456', 25);

      expect(mockGraphService.get).toHaveBeenCalledWith(
        '/teams/team-123/channels/channel-456/messages',
        expect.objectContaining({ $top: 25 })
      );
      expect(result).toEqual(mockMessages);
    });
  });

  describe('getMyChats', () => {
    it('should fetch all chats for the current user', async () => {
      const mockChats = [
        {
          id: 'chat-1',
          topic: 'Project Discussion',
          chatType: 'group',
          createdDateTime: '2024-01-01T10:00:00Z'
        },
        {
          id: 'chat-2',
          chatType: 'oneOnOne',
          createdDateTime: '2024-01-02T10:00:00Z'
        }
      ];

      mockGraphService.get = jest.fn().mockResolvedValue({ value: mockChats });

      const result = await teamsService.getMyChats();

      expect(mockGraphService.get).toHaveBeenCalledWith(
        '/me/chats',
        expect.any(Object)
      );
      expect(result).toEqual(mockChats);
    });
  });

  describe('getChatMessages', () => {
    it('should fetch messages from a specific chat', async () => {
      const mockMessages = [
        {
          id: 'msg-1',
          createdDateTime: '2024-01-01T10:00:00Z',
          body: { contentType: 'text', content: 'Hello there!' }
        }
      ];

      mockGraphService.get = jest.fn().mockResolvedValue({ value: mockMessages });

      const result = await teamsService.getChatMessages('chat-123', 30);

      expect(mockGraphService.get).toHaveBeenCalledWith(
        '/me/chats/chat-123/messages',
        expect.objectContaining({ $top: 30 })
      );
      expect(result).toEqual(mockMessages);
    });
  });

  describe('getChatMembers', () => {
    it('should fetch members of a chat', async () => {
      const mockMembers = [
        { id: 'member-1', displayName: 'Alice', email: 'alice@example.com' },
        { id: 'member-2', displayName: 'Bob', email: 'bob@example.com' }
      ];

      mockGraphService.get = jest.fn().mockResolvedValue({ value: mockMembers });

      const result = await teamsService.getChatMembers('chat-123');

      expect(mockGraphService.get).toHaveBeenCalledWith('/me/chats/chat-123/members');
      expect(result).toHaveLength(2);
      expect(result[0]).toHaveProperty('displayName', 'Alice');
    });
  });

  describe('sendChatMessage', () => {
    it('should send a message to a chat', async () => {
      const mockResponse = {
        id: 'new-msg-id',
        createdDateTime: '2024-01-01T10:00:00Z',
        body: { contentType: 'html', content: '<p>Test message</p>' }
      };

      mockGraphService.post = jest.fn().mockResolvedValue(mockResponse);

      const result = await teamsService.sendChatMessage('chat-123', '<p>Test message</p>');

      expect(mockGraphService.post).toHaveBeenCalledWith(
        '/me/chats/chat-123/messages',
        {
          body: {
            contentType: 'html',
            content: '<p>Test message</p>'
          }
        }
      );
      expect(result).toEqual(mockResponse);
    });
  });

  describe('getChat', () => {
    it('should fetch a specific chat with members', async () => {
      const mockChat = {
        id: 'chat-123',
        topic: 'Important Chat',
        chatType: 'group',
        createdDateTime: '2024-01-01T10:00:00Z'
      };

      const mockMembers = [
        { id: 'm-1', displayName: 'User 1', email: 'user1@example.com' }
      ];

      mockGraphService.get = jest.fn()
        .mockResolvedValueOnce(mockChat)
        .mockResolvedValueOnce({ value: mockMembers });

      const result = await teamsService.getChat('chat-123');

      expect(result).toHaveProperty('id', 'chat-123');
      expect(result).toHaveProperty('members');
      expect(result.members).toHaveLength(1);
    });
  });
});
