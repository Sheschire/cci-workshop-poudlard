import { GraphService } from './graph';

export interface EmailMessage {
  id: string;
  subject: string;
  bodyPreview: string;
  body?: {
    contentType: string;
    content: string;
  };
  from?: {
    emailAddress: {
      name: string;
      address: string;
    };
  };
  toRecipients?: Array<{
    emailAddress: {
      name: string;
      address: string;
    };
  }>;
  receivedDateTime: string;
  isRead: boolean;
  hasAttachments: boolean;
}

export interface SendEmailParams {
  to: string[];
  subject: string;
  body: string;
  contentType?: 'Text' | 'HTML';
  cc?: string[];
  bcc?: string[];
}

export class MailService {
  private graphService: GraphService;

  constructor(accessToken: string) {
    this.graphService = new GraphService(accessToken);
  }

  /**
   * Get messages from inbox
   * @param top - Number of messages to retrieve (default: 25)
   * @param skip - Number of messages to skip for pagination
   */
  async getInbox(top: number = 25, skip: number = 0): Promise<{ messages: EmailMessage[]; total: number }> {
    const response = await this.graphService.get('/me/mailFolders/inbox/messages', {
      $top: top,
      $select: 'id,subject,bodyPreview,from,toRecipients,receivedDateTime,isRead,hasAttachments',
      $orderby: 'receivedDateTime DESC'
    });

    return {
      messages: response.value,
      total: response['@odata.count'] || response.value.length
    };
  }

  /**
   * Get a specific message by ID
   * @param messageId - The message ID
   */
  async getMessage(messageId: string): Promise<EmailMessage> {
    return this.graphService.get(`/me/messages/${messageId}`, {
      $select: 'id,subject,body,bodyPreview,from,toRecipients,receivedDateTime,isRead,hasAttachments'
    });
  }

  /**
   * Send an email
   * @param params - Email parameters
   */
  async sendEmail(params: SendEmailParams): Promise<void> {
    const message = {
      message: {
        subject: params.subject,
        body: {
          contentType: params.contentType || 'HTML',
          content: params.body
        },
        toRecipients: params.to.map(email => ({
          emailAddress: { address: email }
        })),
        ccRecipients: params.cc?.map(email => ({
          emailAddress: { address: email }
        })) || [],
        bccRecipients: params.bcc?.map(email => ({
          emailAddress: { address: email }
        })) || []
      },
      saveToSentItems: true
    };

    await this.graphService.post('/me/sendMail', message);
  }

  /**
   * Mark a message as read
   * @param messageId - The message ID
   */
  async markAsRead(messageId: string): Promise<void> {
    await this.graphService.post(`/me/messages/${messageId}`, {
      isRead: true
    });
  }

  /**
   * Delete a message
   * @param messageId - The message ID
   */
  async deleteMessage(messageId: string): Promise<void> {
    await this.graphService.delete(`/me/messages/${messageId}`);
  }

  /**
   * Get sent messages
   * @param top - Number of messages to retrieve
   */
  async getSentItems(top: number = 25): Promise<{ messages: EmailMessage[] }> {
    const response = await this.graphService.get('/me/mailFolders/sentitems/messages', {
      $top: top,
      $select: 'id,subject,bodyPreview,from,toRecipients,receivedDateTime,isRead,hasAttachments',
      $orderby: 'receivedDateTime DESC'
    });

    return {
      messages: response.value
    };
  }
}
