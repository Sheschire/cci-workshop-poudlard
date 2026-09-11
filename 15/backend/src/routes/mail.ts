import { Router, Request, Response } from 'express';
import { requireAuth, getAccessToken } from '../middleware/auth.middleware';
import { MailService } from '../services/mail.service';

const router = Router();

// All mail routes require authentication
router.use(requireAuth);

/**
 * GET /mail/inbox
 * Get messages from inbox
 * Query params: top (number), skip (number)
 */
router.get('/inbox', async (req: Request, res: Response) => {
  try {
    const accessToken = getAccessToken(req);
    const mailService = new MailService(accessToken);

    const top = parseInt(req.query.top as string) || 25;
    const skip = parseInt(req.query.skip as string) || 0;

    const result = await mailService.getInbox(top, skip);

    res.json(result);
  } catch (error: any) {
    console.error('Get inbox error:', error);
    res.status(500).json({
      error: 'Failed to get inbox',
      message: error.message
    });
  }
});

/**
 * GET /mail/sent
 * Get sent messages
 * Query params: top (number)
 */
router.get('/sent', async (req: Request, res: Response) => {
  try {
    const accessToken = getAccessToken(req);
    const mailService = new MailService(accessToken);

    const top = parseInt(req.query.top as string) || 25;

    const result = await mailService.getSentItems(top);

    res.json(result);
  } catch (error: any) {
    console.error('Get sent items error:', error);
    res.status(500).json({
      error: 'Failed to get sent items',
      message: error.message
    });
  }
});

/**
 * GET /mail/message/:id
 * Get a specific message by ID
 */
router.get('/message/:id', async (req: Request, res: Response) => {
  try {
    const accessToken = getAccessToken(req);
    const mailService = new MailService(accessToken);

    const message = await mailService.getMessage(req.params.id);

    res.json(message);
  } catch (error: any) {
    console.error('Get message error:', error);
    res.status(500).json({
      error: 'Failed to get message',
      message: error.message
    });
  }
});

/**
 * POST /mail/send
 * Send an email
 * Body: { to: string[], subject: string, body: string, contentType?: 'Text' | 'HTML', cc?: string[], bcc?: string[] }
 */
router.post('/send', async (req: Request, res: Response) => {
  try {
    const accessToken = getAccessToken(req);
    const mailService = new MailService(accessToken);

    const { to, subject, body, contentType, cc, bcc } = req.body;

    if (!to || !Array.isArray(to) || to.length === 0) {
      res.status(400).json({
        error: 'Validation error',
        message: 'At least one recipient (to) is required'
      });
      return;
    }

    if (!subject) {
      res.status(400).json({
        error: 'Validation error',
        message: 'Subject is required'
      });
      return;
    }

    if (!body) {
      res.status(400).json({
        error: 'Validation error',
        message: 'Body is required'
      });
      return;
    }

    await mailService.sendEmail({
      to,
      subject,
      body,
      contentType: contentType || 'HTML',
      cc,
      bcc
    });

    res.json({
      success: true,
      message: 'Email sent successfully'
    });
  } catch (error: any) {
    console.error('Send email error:', error);
    res.status(500).json({
      error: 'Failed to send email',
      message: error.message
    });
  }
});

/**
 * PATCH /mail/message/:id/read
 * Mark a message as read
 */
router.patch('/message/:id/read', async (req: Request, res: Response) => {
  try {
    const accessToken = getAccessToken(req);
    const mailService = new MailService(accessToken);

    await mailService.markAsRead(req.params.id);

    res.json({
      success: true,
      message: 'Message marked as read'
    });
  } catch (error: any) {
    console.error('Mark as read error:', error);
    res.status(500).json({
      error: 'Failed to mark message as read',
      message: error.message
    });
  }
});

/**
 * DELETE /mail/message/:id
 * Delete a message
 */
router.delete('/message/:id', async (req: Request, res: Response) => {
  try {
    const accessToken = getAccessToken(req);
    const mailService = new MailService(accessToken);

    await mailService.deleteMessage(req.params.id);

    res.json({
      success: true,
      message: 'Message deleted'
    });
  } catch (error: any) {
    console.error('Delete message error:', error);
    res.status(500).json({
      error: 'Failed to delete message',
      message: error.message
    });
  }
});

export default router;
