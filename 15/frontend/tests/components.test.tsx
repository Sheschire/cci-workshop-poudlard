import React from 'react';
import { render, screen, fireEvent } from '@testing-library/react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import MailList from '@/components/MailList';
import { EmailMessage } from '@/lib/api';

// Helper to wrap components with QueryClientProvider
const createWrapper = () => {
  const queryClient = new QueryClient({
    defaultOptions: {
      queries: {
        retry: false
      }
    }
  });
  return ({ children }: { children: React.ReactNode }) => (
    <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
  );
};

describe('MailList', () => {
  const mockMessages: EmailMessage[] = [
    {
      id: '1',
      subject: 'Test Email 1',
      bodyPreview: 'This is the preview of email 1',
      from: {
        emailAddress: {
          name: 'John Doe',
          address: 'john@example.com'
        }
      },
      receivedDateTime: new Date().toISOString(),
      isRead: false,
      hasAttachments: false
    },
    {
      id: '2',
      subject: 'Test Email 2',
      bodyPreview: 'This is the preview of email 2',
      from: {
        emailAddress: {
          name: 'Jane Smith',
          address: 'jane@example.com'
        }
      },
      receivedDateTime: new Date(Date.now() - 86400000).toISOString(), // Yesterday
      isRead: true,
      hasAttachments: true
    }
  ];

  it('renders a list of messages', () => {
    const mockOnSelect = jest.fn();

    render(
      <MailList
        messages={mockMessages}
        onSelect={mockOnSelect}
      />
    );

    expect(screen.getByText('Test Email 1')).toBeInTheDocument();
    expect(screen.getByText('Test Email 2')).toBeInTheDocument();
    expect(screen.getByText('John Doe')).toBeInTheDocument();
    expect(screen.getByText('Jane Smith')).toBeInTheDocument();
  });

  it('shows empty state when no messages', () => {
    const mockOnSelect = jest.fn();

    render(
      <MailList
        messages={[]}
        onSelect={mockOnSelect}
      />
    );

    expect(screen.getByText('Aucun email trouve')).toBeInTheDocument();
  });

  it('shows loading state', () => {
    const mockOnSelect = jest.fn();

    render(
      <MailList
        messages={[]}
        onSelect={mockOnSelect}
        isLoading={true}
      />
    );

    // Should show loading skeletons (animated divs)
    const skeletons = document.querySelectorAll('.animate-pulse');
    expect(skeletons.length).toBeGreaterThan(0);
  });

  it('calls onSelect when clicking a message', () => {
    const mockOnSelect = jest.fn();

    render(
      <MailList
        messages={mockMessages}
        onSelect={mockOnSelect}
      />
    );

    fireEvent.click(screen.getByText('Test Email 1'));

    expect(mockOnSelect).toHaveBeenCalledWith(mockMessages[0]);
  });

  it('highlights selected message', () => {
    const mockOnSelect = jest.fn();

    render(
      <MailList
        messages={mockMessages}
        selectedId="1"
        onSelect={mockOnSelect}
      />
    );

    // The selected message should have the active class
    const buttons = document.querySelectorAll('button');
    const selectedButton = Array.from(buttons).find(btn =>
      btn.classList.contains('bg-hedwige-100')
    );
    expect(selectedButton).toBeTruthy();
  });

  it('shows unread indicator for unread messages', () => {
    const mockOnSelect = jest.fn();

    render(
      <MailList
        messages={mockMessages}
        onSelect={mockOnSelect}
      />
    );

    // Unread message should have the blue dot indicator
    const unreadIndicator = document.querySelector('.bg-hedwige-600.rounded-full');
    expect(unreadIndicator).toBeInTheDocument();
  });

  it('shows attachment icon for messages with attachments', () => {
    const mockOnSelect = jest.fn();

    render(
      <MailList
        messages={mockMessages}
        onSelect={mockOnSelect}
      />
    );

    // Should show the paperclip emoji for messages with attachments
    expect(screen.getByText('📎')).toBeInTheDocument();
  });

  it('displays "(Sans objet)" for messages without subject', () => {
    const mockOnSelect = jest.fn();
    const messagesWithoutSubject: EmailMessage[] = [
      {
        ...mockMessages[0],
        subject: ''
      }
    ];

    render(
      <MailList
        messages={messagesWithoutSubject}
        onSelect={mockOnSelect}
      />
    );

    expect(screen.getByText('(Sans objet)')).toBeInTheDocument();
  });

  it('displays "Inconnu" when sender is missing', () => {
    const mockOnSelect = jest.fn();
    const messagesWithoutFrom: EmailMessage[] = [
      {
        ...mockMessages[0],
        from: undefined
      }
    ];

    render(
      <MailList
        messages={messagesWithoutFrom}
        onSelect={mockOnSelect}
      />
    );

    expect(screen.getByText('Inconnu')).toBeInTheDocument();
  });
});

describe('API client', () => {
  // Test that the API module exports the expected functions
  it('exports all required API functions', async () => {
    const api = await import('@/lib/api');

    expect(api.authApi).toBeDefined();
    expect(api.authApi.getStatus).toBeDefined();
    expect(api.authApi.getLoginUrl).toBeDefined();
    expect(api.authApi.getLogoutUrl).toBeDefined();

    expect(api.mailApi).toBeDefined();
    expect(api.mailApi.getInbox).toBeDefined();
    expect(api.mailApi.sendEmail).toBeDefined();
    expect(api.mailApi.getMessage).toBeDefined();

    expect(api.onedriveApi).toBeDefined();
    expect(api.onedriveApi.getFiles).toBeDefined();
    expect(api.onedriveApi.uploadFile).toBeDefined();

    expect(api.teamsApi).toBeDefined();
    expect(api.teamsApi.getTeams).toBeDefined();
    expect(api.teamsApi.getChats).toBeDefined();
  });
});
