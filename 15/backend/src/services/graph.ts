import { Client } from '@microsoft/microsoft-graph-client';
import 'isomorphic-fetch';

/**
 * Creates an authenticated Microsoft Graph client
 * @param accessToken - The OAuth access token
 * @returns Microsoft Graph Client instance
 */
export function createGraphClient(accessToken: string): Client {
  return Client.init({
    authProvider: (done) => {
      done(null, accessToken);
    }
  });
}

/**
 * GraphService class for making Microsoft Graph API calls
 */
export class GraphService {
  private client: Client;

  constructor(accessToken: string) {
    this.client = createGraphClient(accessToken);
  }

  /**
   * Get the current user's profile
   */
  async getMe(): Promise<any> {
    return this.client.api('/me').get();
  }

  /**
   * Generic GET request to Graph API
   */
  async get(endpoint: string, params?: Record<string, any>): Promise<any> {
    let request = this.client.api(endpoint);
    if (params) {
      if (params.$top) request = request.top(params.$top);
      if (params.$select) request = request.select(params.$select);
      if (params.$filter) request = request.filter(params.$filter);
      if (params.$orderby) request = request.orderby(params.$orderby);
    }
    return request.get();
  }

  /**
   * Generic POST request to Graph API
   */
  async post(endpoint: string, body: any): Promise<any> {
    return this.client.api(endpoint).post(body);
  }

  /**
   * Generic PUT request to Graph API
   */
  async put(endpoint: string, body: any): Promise<any> {
    return this.client.api(endpoint).put(body);
  }

  /**
   * Generic DELETE request to Graph API
   */
  async delete(endpoint: string): Promise<void> {
    return this.client.api(endpoint).delete();
  }

  /**
   * Get raw content (for file downloads)
   */
  async getContent(endpoint: string): Promise<ArrayBuffer> {
    return this.client.api(endpoint).get();
  }
}
