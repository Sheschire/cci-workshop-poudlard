import { Router, Request, Response } from 'express';
import { requireAuth, getAccessToken } from '../middleware/auth.middleware';
import { TeamsService } from '../services/teams.service';

const router = Router();

// All Teams routes require authentication
router.use(requireAuth);

/**
 * GET /teams
 * Get all teams the user is a member of
 */
router.get('/', async (req: Request, res: Response) => {
  try {
    const accessToken = getAccessToken(req);
    const teamsService = new TeamsService(accessToken);

    const teams = await teamsService.getMyTeams();

    res.json({ teams });
  } catch (error: any) {
    console.error('Get teams error:', error);
    res.status(500).json({
      error: 'Failed to get teams',
      message: error.message
    });
  }
});

/**
 * GET /teams/:teamId/channels
 * Get channels for a specific team
 */
router.get('/:teamId/channels', async (req: Request, res: Response) => {
  try {
    const accessToken = getAccessToken(req);
    const teamsService = new TeamsService(accessToken);

    const channels = await teamsService.getTeamChannels(req.params.teamId);

    res.json({ channels });
  } catch (error: any) {
    console.error('Get channels error:', error);
    res.status(500).json({
      error: 'Failed to get channels',
      message: error.message
    });
  }
});

/**
 * GET /teams/:teamId/channels/:channelId/messages
 * Get messages from a channel
 * Query params: top (number)
 */
router.get('/:teamId/channels/:channelId/messages', async (req: Request, res: Response) => {
  try {
    const accessToken = getAccessToken(req);
    const teamsService = new TeamsService(accessToken);

    const top = parseInt(req.query.top as string) || 50;

    const messages = await teamsService.getChannelMessages(
      req.params.teamId,
      req.params.channelId,
      top
    );

    res.json({ messages });
  } catch (error: any) {
    console.error('Get channel messages error:', error);
    res.status(500).json({
      error: 'Failed to get channel messages',
      message: error.message
    });
  }
});

/**
 * GET /teams/chats
 * Get all chats for the current user
 */
router.get('/chats', async (req: Request, res: Response) => {
  try {
    const accessToken = getAccessToken(req);
    const teamsService = new TeamsService(accessToken);

    const chats = await teamsService.getMyChats();

    res.json({ chats });
  } catch (error: any) {
    console.error('Get chats error:', error);
    res.status(500).json({
      error: 'Failed to get chats',
      message: error.message
    });
  }
});

/**
 * GET /teams/chats/:chatId
 * Get a specific chat with members
 */
router.get('/chats/:chatId', async (req: Request, res: Response) => {
  try {
    const accessToken = getAccessToken(req);
    const teamsService = new TeamsService(accessToken);

    const chat = await teamsService.getChat(req.params.chatId);

    res.json(chat);
  } catch (error: any) {
    console.error('Get chat error:', error);
    res.status(500).json({
      error: 'Failed to get chat',
      message: error.message
    });
  }
});

/**
 * GET /teams/chats/:chatId/messages
 * Get messages from a chat
 * Query params: top (number)
 */
router.get('/chats/:chatId/messages', async (req: Request, res: Response) => {
  try {
    const accessToken = getAccessToken(req);
    const teamsService = new TeamsService(accessToken);

    const top = parseInt(req.query.top as string) || 50;

    const messages = await teamsService.getChatMessages(req.params.chatId, top);

    res.json({ messages });
  } catch (error: any) {
    console.error('Get chat messages error:', error);
    res.status(500).json({
      error: 'Failed to get chat messages',
      message: error.message
    });
  }
});

/**
 * POST /teams/chats/:chatId/messages
 * Send a message to a chat
 * Body: { content: string }
 */
router.post('/chats/:chatId/messages', async (req: Request, res: Response) => {
  try {
    const accessToken = getAccessToken(req);
    const teamsService = new TeamsService(accessToken);

    const { content } = req.body;

    if (!content) {
      res.status(400).json({
        error: 'Validation error',
        message: 'Message content is required'
      });
      return;
    }

    const message = await teamsService.sendChatMessage(req.params.chatId, content);

    res.json({
      success: true,
      message
    });
  } catch (error: any) {
    console.error('Send chat message error:', error);
    res.status(500).json({
      error: 'Failed to send message',
      message: error.message
    });
  }
});

export default router;
