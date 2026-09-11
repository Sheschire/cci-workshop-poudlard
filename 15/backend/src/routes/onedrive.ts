import { Router, Request, Response } from 'express';
import { requireAuth, getAccessToken } from '../middleware/auth.middleware';
import { OneDriveService } from '../services/onedrive.service';

const router = Router();

// All OneDrive routes require authentication
router.use(requireAuth);

/**
 * GET /onedrive/files
 * Get files from root or specific folder
 * Query params: folderId (optional), path (optional), top (number)
 */
router.get('/files', async (req: Request, res: Response) => {
  try {
    const accessToken = getAccessToken(req);
    const oneDriveService = new OneDriveService(accessToken);

    const folderId = req.query.folderId as string;
    const path = req.query.path as string;
    const top = parseInt(req.query.top as string) || 50;

    let result;

    if (path) {
      result = await oneDriveService.getItemsByPath(path, top);
    } else if (folderId) {
      result = await oneDriveService.getFolderItems(folderId, top);
    } else {
      result = await oneDriveService.getRootItems(top);
    }

    res.json(result);
  } catch (error: any) {
    console.error('Get files error:', error);
    res.status(500).json({
      error: 'Failed to get files',
      message: error.message
    });
  }
});

/**
 * GET /onedrive/item/:id
 * Get a specific item by ID
 */
router.get('/item/:id', async (req: Request, res: Response) => {
  try {
    const accessToken = getAccessToken(req);
    const oneDriveService = new OneDriveService(accessToken);

    const item = await oneDriveService.getItem(req.params.id);

    res.json(item);
  } catch (error: any) {
    console.error('Get item error:', error);
    res.status(500).json({
      error: 'Failed to get item',
      message: error.message
    });
  }
});

/**
 * GET /onedrive/download/:id
 * Get download URL for a file
 */
router.get('/download/:id', async (req: Request, res: Response) => {
  try {
    const accessToken = getAccessToken(req);
    const oneDriveService = new OneDriveService(accessToken);

    const downloadUrl = await oneDriveService.getDownloadUrl(req.params.id);

    res.json({ downloadUrl });
  } catch (error: any) {
    console.error('Get download URL error:', error);
    res.status(500).json({
      error: 'Failed to get download URL',
      message: error.message
    });
  }
});

/**
 * GET /onedrive/content/:id
 * Download file content directly
 */
router.get('/content/:id', async (req: Request, res: Response) => {
  try {
    const accessToken = getAccessToken(req);
    const oneDriveService = new OneDriveService(accessToken);

    // Get item info first for filename and content type
    const item = await oneDriveService.getItem(req.params.id);

    if (item.folder) {
      res.status(400).json({
        error: 'Invalid request',
        message: 'Cannot download a folder'
      });
      return;
    }

    const content = await oneDriveService.downloadFile(req.params.id);

    res.setHeader('Content-Disposition', `attachment; filename="${item.name}"`);
    res.setHeader('Content-Type', item.file?.mimeType || 'application/octet-stream');
    res.send(Buffer.from(content));
  } catch (error: any) {
    console.error('Download file error:', error);
    res.status(500).json({
      error: 'Failed to download file',
      message: error.message
    });
  }
});

/**
 * POST /onedrive/upload
 * Upload a file
 * Body: { parentId: string (or 'root'), fileName: string, content: base64 string }
 */
router.post('/upload', async (req: Request, res: Response) => {
  try {
    const accessToken = getAccessToken(req);
    const oneDriveService = new OneDriveService(accessToken);

    const { parentId, fileName, content } = req.body;

    if (!fileName) {
      res.status(400).json({
        error: 'Validation error',
        message: 'fileName is required'
      });
      return;
    }

    if (!content) {
      res.status(400).json({
        error: 'Validation error',
        message: 'content (base64) is required'
      });
      return;
    }

    const buffer = Buffer.from(content, 'base64');

    // Check file size (4MB limit for simple upload)
    if (buffer.length > 4 * 1024 * 1024) {
      res.status(400).json({
        error: 'File too large',
        message: 'File must be less than 4MB for simple upload'
      });
      return;
    }

    const result = await oneDriveService.uploadSmallFile(
      parentId || 'root',
      fileName,
      buffer
    );

    res.json({
      success: true,
      item: result
    });
  } catch (error: any) {
    console.error('Upload file error:', error);
    res.status(500).json({
      error: 'Failed to upload file',
      message: error.message
    });
  }
});

/**
 * POST /onedrive/folder
 * Create a new folder
 * Body: { parentId: string (or 'root'), folderName: string }
 */
router.post('/folder', async (req: Request, res: Response) => {
  try {
    const accessToken = getAccessToken(req);
    const oneDriveService = new OneDriveService(accessToken);

    const { parentId, folderName } = req.body;

    if (!folderName) {
      res.status(400).json({
        error: 'Validation error',
        message: 'folderName is required'
      });
      return;
    }

    const result = await oneDriveService.createFolder(
      parentId || 'root',
      folderName
    );

    res.json({
      success: true,
      item: result
    });
  } catch (error: any) {
    console.error('Create folder error:', error);
    res.status(500).json({
      error: 'Failed to create folder',
      message: error.message
    });
  }
});

/**
 * DELETE /onedrive/item/:id
 * Delete an item
 */
router.delete('/item/:id', async (req: Request, res: Response) => {
  try {
    const accessToken = getAccessToken(req);
    const oneDriveService = new OneDriveService(accessToken);

    await oneDriveService.deleteItem(req.params.id);

    res.json({
      success: true,
      message: 'Item deleted'
    });
  } catch (error: any) {
    console.error('Delete item error:', error);
    res.status(500).json({
      error: 'Failed to delete item',
      message: error.message
    });
  }
});

/**
 * GET /onedrive/search
 * Search for files
 * Query params: q (search query)
 */
router.get('/search', async (req: Request, res: Response) => {
  try {
    const accessToken = getAccessToken(req);
    const oneDriveService = new OneDriveService(accessToken);

    const query = req.query.q as string;

    if (!query) {
      res.status(400).json({
        error: 'Validation error',
        message: 'Search query (q) is required'
      });
      return;
    }

    const result = await oneDriveService.searchItems(query);

    res.json(result);
  } catch (error: any) {
    console.error('Search error:', error);
    res.status(500).json({
      error: 'Failed to search',
      message: error.message
    });
  }
});

export default router;
