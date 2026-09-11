import { OneDriveService } from '../src/services/onedrive.service';
import { GraphService } from '../src/services/graph';

// Mock the GraphService
jest.mock('../src/services/graph');

describe('OneDriveService', () => {
  let oneDriveService: OneDriveService;
  let mockGraphService: jest.Mocked<GraphService>;

  beforeEach(() => {
    jest.clearAllMocks();
    oneDriveService = new OneDriveService('mock-access-token');
    mockGraphService = (GraphService as jest.MockedClass<typeof GraphService>).mock.instances[0] as jest.Mocked<GraphService>;
  });

  describe('getRootItems', () => {
    it('should fetch items from root folder', async () => {
      const mockItems = [
        {
          id: 'folder-1',
          name: 'Documents',
          folder: { childCount: 5 },
          createdDateTime: '2024-01-01T10:00:00Z',
          lastModifiedDateTime: '2024-01-01T10:00:00Z',
          webUrl: 'https://example.com/Documents'
        },
        {
          id: 'file-1',
          name: 'readme.txt',
          size: 1024,
          file: { mimeType: 'text/plain' },
          createdDateTime: '2024-01-01T10:00:00Z',
          lastModifiedDateTime: '2024-01-01T10:00:00Z',
          webUrl: 'https://example.com/readme.txt'
        }
      ];

      mockGraphService.get = jest.fn().mockResolvedValue({ value: mockItems });

      const result = await oneDriveService.getRootItems();

      expect(mockGraphService.get).toHaveBeenCalledWith(
        '/me/drive/root/children',
        expect.objectContaining({
          $top: 50
        })
      );
      expect(result.items).toEqual(mockItems);
    });

    it('should handle pagination', async () => {
      mockGraphService.get = jest.fn().mockResolvedValue({
        value: [],
        '@odata.nextLink': 'https://graph.microsoft.com/next-page'
      });

      const result = await oneDriveService.getRootItems();

      expect(result.nextLink).toBe('https://graph.microsoft.com/next-page');
    });
  });

  describe('getFolderItems', () => {
    it('should fetch items from a specific folder', async () => {
      mockGraphService.get = jest.fn().mockResolvedValue({ value: [] });

      await oneDriveService.getFolderItems('folder-id-123', 25);

      expect(mockGraphService.get).toHaveBeenCalledWith(
        '/me/drive/items/folder-id-123/children',
        expect.objectContaining({
          $top: 25
        })
      );
    });
  });

  describe('getItemsByPath', () => {
    it('should fetch items by path', async () => {
      mockGraphService.get = jest.fn().mockResolvedValue({ value: [] });

      await oneDriveService.getItemsByPath('/Documents/Work');

      expect(mockGraphService.get).toHaveBeenCalledWith(
        expect.stringContaining('/me/drive/root:'),
        expect.any(Object)
      );
    });
  });

  describe('getItem', () => {
    it('should fetch a specific item by ID', async () => {
      const mockItem = {
        id: 'item-123',
        name: 'test.pdf',
        size: 2048
      };

      mockGraphService.get = jest.fn().mockResolvedValue(mockItem);

      const result = await oneDriveService.getItem('item-123');

      expect(mockGraphService.get).toHaveBeenCalledWith(
        '/me/drive/items/item-123',
        expect.any(Object)
      );
      expect(result).toEqual(mockItem);
    });
  });

  describe('getDownloadUrl', () => {
    it('should return download URL for an item', async () => {
      mockGraphService.get = jest.fn().mockResolvedValue({
        '@microsoft.graph.downloadUrl': 'https://download.example.com/file'
      });

      const result = await oneDriveService.getDownloadUrl('item-123');

      expect(result).toBe('https://download.example.com/file');
    });
  });

  describe('uploadSmallFile', () => {
    it('should upload a file to root folder', async () => {
      const mockResult = { id: 'new-file-id', name: 'uploaded.txt' };
      mockGraphService.put = jest.fn().mockResolvedValue(mockResult);

      const content = Buffer.from('Hello World');
      const result = await oneDriveService.uploadSmallFile('root', 'uploaded.txt', content);

      expect(mockGraphService.put).toHaveBeenCalledWith(
        '/me/drive/root:/uploaded.txt:/content',
        content
      );
      expect(result).toEqual(mockResult);
    });

    it('should upload a file to specific folder', async () => {
      mockGraphService.put = jest.fn().mockResolvedValue({});

      const content = Buffer.from('Test');
      await oneDriveService.uploadSmallFile('parent-folder-id', 'test.txt', content);

      expect(mockGraphService.put).toHaveBeenCalledWith(
        '/me/drive/items/parent-folder-id:/test.txt:/content',
        content
      );
    });
  });

  describe('createFolder', () => {
    it('should create a folder in root', async () => {
      const mockFolder = { id: 'new-folder-id', name: 'New Folder' };
      mockGraphService.post = jest.fn().mockResolvedValue(mockFolder);

      const result = await oneDriveService.createFolder('root', 'New Folder');

      expect(mockGraphService.post).toHaveBeenCalledWith(
        '/me/drive/root/children',
        expect.objectContaining({
          name: 'New Folder',
          folder: {}
        })
      );
      expect(result).toEqual(mockFolder);
    });

    it('should create a folder in specific parent', async () => {
      mockGraphService.post = jest.fn().mockResolvedValue({});

      await oneDriveService.createFolder('parent-id', 'Subfolder');

      expect(mockGraphService.post).toHaveBeenCalledWith(
        '/me/drive/items/parent-id/children',
        expect.any(Object)
      );
    });
  });

  describe('deleteItem', () => {
    it('should delete an item', async () => {
      mockGraphService.delete = jest.fn().mockResolvedValue(undefined);

      await oneDriveService.deleteItem('item-123');

      expect(mockGraphService.delete).toHaveBeenCalledWith('/me/drive/items/item-123');
    });
  });

  describe('searchItems', () => {
    it('should search for items', async () => {
      const mockResults = [{ id: '1', name: 'matching-file.txt' }];
      mockGraphService.get = jest.fn().mockResolvedValue({ value: mockResults });

      const result = await oneDriveService.searchItems('matching');

      expect(mockGraphService.get).toHaveBeenCalledWith(
        expect.stringContaining('search')
      );
      expect(result.items).toEqual(mockResults);
    });
  });
});
