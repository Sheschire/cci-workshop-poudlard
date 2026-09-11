import { GraphService } from './graph';

export interface DriveItem {
  id: string;
  name: string;
  size?: number;
  createdDateTime: string;
  lastModifiedDateTime: string;
  webUrl: string;
  folder?: {
    childCount: number;
  };
  file?: {
    mimeType: string;
  };
  parentReference?: {
    id: string;
    path: string;
  };
}

export interface DriveItemsResponse {
  items: DriveItem[];
  nextLink?: string;
}

export class OneDriveService {
  private graphService: GraphService;

  constructor(accessToken: string) {
    this.graphService = new GraphService(accessToken);
  }

  /**
   * Get items in the root of OneDrive
   * @param top - Number of items to retrieve
   */
  async getRootItems(top: number = 50): Promise<DriveItemsResponse> {
    const response = await this.graphService.get('/me/drive/root/children', {
      $top: top,
      $select: 'id,name,size,createdDateTime,lastModifiedDateTime,webUrl,folder,file,parentReference'
    });

    return {
      items: response.value,
      nextLink: response['@odata.nextLink']
    };
  }

  /**
   * Get items in a specific folder
   * @param folderId - The folder ID
   * @param top - Number of items to retrieve
   */
  async getFolderItems(folderId: string, top: number = 50): Promise<DriveItemsResponse> {
    const response = await this.graphService.get(`/me/drive/items/${folderId}/children`, {
      $top: top,
      $select: 'id,name,size,createdDateTime,lastModifiedDateTime,webUrl,folder,file,parentReference'
    });

    return {
      items: response.value,
      nextLink: response['@odata.nextLink']
    };
  }

  /**
   * Get items by path
   * @param path - The path in OneDrive (e.g., "/Documents/Work")
   */
  async getItemsByPath(path: string, top: number = 50): Promise<DriveItemsResponse> {
    const encodedPath = encodeURIComponent(path);
    const response = await this.graphService.get(`/me/drive/root:${encodedPath}:/children`, {
      $top: top,
      $select: 'id,name,size,createdDateTime,lastModifiedDateTime,webUrl,folder,file,parentReference'
    });

    return {
      items: response.value,
      nextLink: response['@odata.nextLink']
    };
  }

  /**
   * Get a specific item by ID
   * @param itemId - The item ID
   */
  async getItem(itemId: string): Promise<DriveItem> {
    return this.graphService.get(`/me/drive/items/${itemId}`, {
      $select: 'id,name,size,createdDateTime,lastModifiedDateTime,webUrl,folder,file,parentReference'
    });
  }

  /**
   * Get download URL for a file
   * @param itemId - The item ID
   */
  async getDownloadUrl(itemId: string): Promise<string> {
    const item = await this.graphService.get(`/me/drive/items/${itemId}`);
    return item['@microsoft.graph.downloadUrl'];
  }

  /**
   * Download file content
   * @param itemId - The item ID
   */
  async downloadFile(itemId: string): Promise<ArrayBuffer> {
    return this.graphService.getContent(`/me/drive/items/${itemId}/content`);
  }

  /**
   * Upload a small file (< 4MB)
   * @param parentId - Parent folder ID (use 'root' for root folder)
   * @param fileName - Name of the file
   * @param content - File content as Buffer
   */
  async uploadSmallFile(parentId: string, fileName: string, content: Buffer): Promise<DriveItem> {
    const endpoint = parentId === 'root'
      ? `/me/drive/root:/${fileName}:/content`
      : `/me/drive/items/${parentId}:/${fileName}:/content`;

    return this.graphService.put(endpoint, content);
  }

  /**
   * Create a new folder
   * @param parentId - Parent folder ID
   * @param folderName - Name of the new folder
   */
  async createFolder(parentId: string, folderName: string): Promise<DriveItem> {
    const endpoint = parentId === 'root'
      ? '/me/drive/root/children'
      : `/me/drive/items/${parentId}/children`;

    return this.graphService.post(endpoint, {
      name: folderName,
      folder: {},
      '@microsoft.graph.conflictBehavior': 'rename'
    });
  }

  /**
   * Delete an item
   * @param itemId - The item ID
   */
  async deleteItem(itemId: string): Promise<void> {
    await this.graphService.delete(`/me/drive/items/${itemId}`);
  }

  /**
   * Search for items
   * @param query - Search query
   */
  async searchItems(query: string): Promise<DriveItemsResponse> {
    const response = await this.graphService.get(`/me/drive/root/search(q='${encodeURIComponent(query)}')`);

    return {
      items: response.value
    };
  }
}
