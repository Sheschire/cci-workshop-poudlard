import { MailService, SendEmailParams } from '../src/services/mail.service';
import { GraphService } from '../src/services/graph';

// Mock the GraphService
jest.mock('../src/services/graph');

describe('MailService', () => {
  let mailService: MailService;
  let mockGraphService: jest.Mocked<GraphService>;

  beforeEach(() => {
    jest.clearAllMocks();
    mailService = new MailService('mock-access-token');
    mockGraphService = (GraphService as jest.MockedClass<typeof GraphService>).mock.instances[0] as jest.Mocked<GraphService>;
  });

  describe('getInbox', () => {
    it('should fetch inbox messages with default parameters', async () => {
      const mockMessages = [
        {
          id: '1',
          subject: 'Test Email',
          bodyPreview: 'This is a test',
          receivedDateTime: '2024-01-01T10:00:00Z',
          isRead: false,
          hasAttachments: false
        }
      ];

      mockGraphService.get = jest.fn().mockResolvedValue({
        value: mockMessages
      });

      const result = await mailService.getInbox();

      expect(mockGraphService.get).toHaveBeenCalledWith(
        '/me/mailFolders/inbox/messages',
        expect.objectContaining({
          $top: 25,
          $orderby: 'receivedDateTime DESC'
        })
      );
      expect(result.messages).toEqual(mockMessages);
    });

    it('should fetch inbox messages with custom parameters', async () => {
      mockGraphService.get = jest.fn().mockResolvedValue({ value: [] });

      await mailService.getInbox(10, 5);

      expect(mockGraphService.get).toHaveBeenCalledWith(
        '/me/mailFolders/inbox/messages',
        expect.objectContaining({
          $top: 10
        })
      );
    });
  });

  describe('getMessage', () => {
    it('should fetch a specific message by ID', async () => {
      const mockMessage = {
        id: 'msg-123',
        subject: 'Test Subject',
        body: { contentType: 'HTML', content: '<p>Hello</p>' }
      };

      mockGraphService.get = jest.fn().mockResolvedValue(mockMessage);

      const result = await mailService.getMessage('msg-123');

      expect(mockGraphService.get).toHaveBeenCalledWith(
        '/me/messages/msg-123',
        expect.any(Object)
      );
      expect(result).toEqual(mockMessage);
    });
  });

  describe('sendEmail', () => {
    it('should send an email with required fields', async () => {
      mockGraphService.post = jest.fn().mockResolvedValue(undefined);

      const emailParams: SendEmailParams = {
        to: ['test@example.com'],
        subject: 'Test Subject',
        body: '<p>Test Body</p>'
      };

      await mailService.sendEmail(emailParams);

      expect(mockGraphService.post).toHaveBeenCalledWith(
        '/me/sendMail',
        expect.objectContaining({
          message: expect.objectContaining({
            subject: 'Test Subject',
            body: {
              contentType: 'HTML',
              content: '<p>Test Body</p>'
            },
            toRecipients: [
              { emailAddress: { address: 'test@example.com' } }
            ]
          }),
          saveToSentItems: true
        })
      );
    });

    it('should send an email with CC and BCC', async () => {
      mockGraphService.post = jest.fn().mockResolvedValue(undefined);

      const emailParams: SendEmailParams = {
        to: ['to@example.com'],
        cc: ['cc@example.com'],
        bcc: ['bcc@example.com'],
        subject: 'Test',
        body: 'Test'
      };

      await mailService.sendEmail(emailParams);

      expect(mockGraphService.post).toHaveBeenCalledWith(
        '/me/sendMail',
        expect.objectContaining({
          message: expect.objectContaining({
            ccRecipients: [{ emailAddress: { address: 'cc@example.com' } }],
            bccRecipients: [{ emailAddress: { address: 'bcc@example.com' } }]
          })
        })
      );
    });
  });

  describe('markAsRead', () => {
    it('should mark a message as read', async () => {
      mockGraphService.post = jest.fn().mockResolvedValue(undefined);

      await mailService.markAsRead('msg-123');

      expect(mockGraphService.post).toHaveBeenCalledWith(
        '/me/messages/msg-123',
        { isRead: true }
      );
    });
  });

  describe('deleteMessage', () => {
    it('should delete a message', async () => {
      mockGraphService.delete = jest.fn().mockResolvedValue(undefined);

      await mailService.deleteMessage('msg-123');

      expect(mockGraphService.delete).toHaveBeenCalledWith('/me/messages/msg-123');
    });
  });

  describe('getSentItems', () => {
    it('should fetch sent items', async () => {
      const mockMessages = [{ id: '1', subject: 'Sent Email' }];
      mockGraphService.get = jest.fn().mockResolvedValue({ value: mockMessages });

      const result = await mailService.getSentItems(10);

      expect(mockGraphService.get).toHaveBeenCalledWith(
        '/me/mailFolders/sentitems/messages',
        expect.objectContaining({
          $top: 10
        })
      );
      expect(result.messages).toEqual(mockMessages);
    });
  });
});
