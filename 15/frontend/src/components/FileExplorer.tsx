'use client';

import { useState, useRef } from 'react';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { onedriveApi, DriveItem } from '@/lib/api';

interface BreadcrumbItem {
  id: string;
  name: string;
}

export default function FileExplorer() {
  const [currentFolderId, setCurrentFolderId] = useState<string | undefined>();
  const [breadcrumbs, setBreadcrumbs] = useState<BreadcrumbItem[]>([]);
  const [showUpload, setShowUpload] = useState(false);
  const [showNewFolder, setShowNewFolder] = useState(false);
  const [newFolderName, setNewFolderName] = useState('');
  const fileInputRef = useRef<HTMLInputElement>(null);

  const queryClient = useQueryClient();

  const { data, isLoading, error } = useQuery({
    queryKey: ['onedrive', currentFolderId],
    queryFn: () => onedriveApi.getFiles(currentFolderId)
  });

  const uploadMutation = useMutation({
    mutationFn: ({ fileName, content }: { fileName: string; content: string }) =>
      onedriveApi.uploadFile(currentFolderId || 'root', fileName, content),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['onedrive', currentFolderId] });
      setShowUpload(false);
    }
  });

  const createFolderMutation = useMutation({
    mutationFn: (folderName: string) =>
      onedriveApi.createFolder(currentFolderId || 'root', folderName),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['onedrive', currentFolderId] });
      setShowNewFolder(false);
      setNewFolderName('');
    }
  });

  const deleteMutation = useMutation({
    mutationFn: onedriveApi.deleteItem,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['onedrive', currentFolderId] });
    }
  });

  const navigateToFolder = (item: DriveItem) => {
    if (item.folder) {
      setCurrentFolderId(item.id);
      setBreadcrumbs([...breadcrumbs, { id: item.id, name: item.name }]);
    }
  };

  const navigateToBreadcrumb = (index: number) => {
    if (index === -1) {
      setCurrentFolderId(undefined);
      setBreadcrumbs([]);
    } else {
      const item = breadcrumbs[index];
      setCurrentFolderId(item.id);
      setBreadcrumbs(breadcrumbs.slice(0, index + 1));
    }
  };

  const handleDownload = async (item: DriveItem) => {
    try {
      const { downloadUrl } = await onedriveApi.getDownloadUrl(item.id);
      window.open(downloadUrl, '_blank');
    } catch (err) {
      alert('Erreur lors du telechargement');
    }
  };

  const handleFileUpload = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;

    const reader = new FileReader();
    reader.onload = () => {
      const base64 = (reader.result as string).split(',')[1];
      uploadMutation.mutate({ fileName: file.name, content: base64 });
    };
    reader.readAsDataURL(file);
  };

  const handleDelete = (item: DriveItem) => {
    if (confirm(`Supprimer "${item.name}" ?`)) {
      deleteMutation.mutate(item.id);
    }
  };

  const formatSize = (bytes?: number) => {
    if (!bytes) return '-';
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  };

  const formatDate = (dateString: string) => {
    return new Date(dateString).toLocaleDateString('fr-FR', {
      day: 'numeric',
      month: 'short',
      year: 'numeric'
    });
  };

  if (error) {
    return (
      <div className="card text-red-600">
        Erreur: {(error as Error).message}
      </div>
    );
  }

  return (
    <div className="space-y-4">
      {/* Toolbar */}
      <div className="flex items-center justify-between">
        <div className="flex items-center space-x-2">
          <button
            onClick={() => navigateToBreadcrumb(-1)}
            className="nav-link"
          >
            🏠 Racine
          </button>
          {breadcrumbs.map((item, index) => (
            <span key={item.id} className="flex items-center">
              <span className="text-hedwige-400 mx-1">/</span>
              <button
                onClick={() => navigateToBreadcrumb(index)}
                className="nav-link"
              >
                {item.name}
              </button>
            </span>
          ))}
        </div>

        <div className="flex items-center space-x-2">
          <button
            onClick={() => setShowNewFolder(true)}
            className="btn-secondary text-sm"
          >
            📁 Nouveau dossier
          </button>
          <button
            onClick={() => fileInputRef.current?.click()}
            className="btn-primary text-sm"
            disabled={uploadMutation.isPending}
          >
            {uploadMutation.isPending ? 'Upload...' : '⬆️ Upload'}
          </button>
          <input
            ref={fileInputRef}
            type="file"
            onChange={handleFileUpload}
            className="hidden"
          />
        </div>
      </div>

      {/* New Folder Dialog */}
      {showNewFolder && (
        <div className="card flex items-center space-x-2">
          <input
            type="text"
            value={newFolderName}
            onChange={(e) => setNewFolderName(e.target.value)}
            placeholder="Nom du dossier"
            className="input flex-1"
            autoFocus
          />
          <button
            onClick={() => createFolderMutation.mutate(newFolderName)}
            className="btn-primary"
            disabled={!newFolderName || createFolderMutation.isPending}
          >
            Creer
          </button>
          <button
            onClick={() => {
              setShowNewFolder(false);
              setNewFolderName('');
            }}
            className="btn-secondary"
          >
            Annuler
          </button>
        </div>
      )}

      {/* File List */}
      <div className="card overflow-hidden p-0">
        {isLoading ? (
          <div className="p-8 text-center text-hedwige-600">Chargement...</div>
        ) : data?.items.length === 0 ? (
          <div className="p-8 text-center text-hedwige-600">Dossier vide</div>
        ) : (
          <table className="w-full">
            <thead className="bg-hedwige-50 border-b border-hedwige-100">
              <tr>
                <th className="text-left py-3 px-4 text-hedwige-700 font-medium">Nom</th>
                <th className="text-left py-3 px-4 text-hedwige-700 font-medium w-24">Taille</th>
                <th className="text-left py-3 px-4 text-hedwige-700 font-medium w-32">Modifie</th>
                <th className="text-right py-3 px-4 text-hedwige-700 font-medium w-24">Actions</th>
              </tr>
            </thead>
            <tbody>
              {data?.items.map((item) => (
                <tr
                  key={item.id}
                  className="border-b border-hedwige-50 hover:bg-hedwige-50 transition-colors"
                >
                  <td className="py-3 px-4">
                    {item.folder ? (
                      <button
                        onClick={() => navigateToFolder(item)}
                        className="flex items-center space-x-2 text-hedwige-800 hover:text-hedwige-600"
                      >
                        <span>📁</span>
                        <span>{item.name}</span>
                      </button>
                    ) : (
                      <div className="flex items-center space-x-2 text-hedwige-800">
                        <span>📄</span>
                        <span>{item.name}</span>
                      </div>
                    )}
                  </td>
                  <td className="py-3 px-4 text-hedwige-600 text-sm">
                    {item.folder ? `${item.folder.childCount} elements` : formatSize(item.size)}
                  </td>
                  <td className="py-3 px-4 text-hedwige-600 text-sm">
                    {formatDate(item.lastModifiedDateTime)}
                  </td>
                  <td className="py-3 px-4 text-right space-x-2">
                    {!item.folder && (
                      <button
                        onClick={() => handleDownload(item)}
                        className="text-hedwige-600 hover:text-hedwige-800"
                        title="Telecharger"
                      >
                        ⬇️
                      </button>
                    )}
                    <button
                      onClick={() => handleDelete(item)}
                      className="text-red-500 hover:text-red-700"
                      title="Supprimer"
                    >
                      🗑️
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </div>
  );
}
