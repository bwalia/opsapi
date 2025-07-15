const API_BASE_URL = process.env.NEXT_PUBLIC_API_URL || 'http://localhost:4010';

class ApiClient {
  private baseURL: string;
  private token: string | null = null;

  constructor(baseURL: string) {
    this.baseURL = baseURL;
    if (typeof window !== 'undefined') {
      this.token = localStorage.getItem('token');
    }
  }

  private async request(endpoint: string, options: RequestInit = {}, useFormData = false) {
    const url = `${this.baseURL}${endpoint}`;
    
    let body = options.body;
    let headers: any = {
      ...(this.token && { Authorization: `Bearer ${this.token}` }),
      ...options.headers,
    };

    if (useFormData && options.body && typeof options.body === 'string') {
      const data = JSON.parse(options.body);
      body = new URLSearchParams(data).toString();
      headers['Content-Type'] = 'application/x-www-form-urlencoded';
    } else if (!useFormData) {
      headers['Content-Type'] = 'application/json';
    }

    const response = await fetch(url, { ...options, headers, body });
    
    if (!response.ok) {
      const error = await response.json().catch(() => ({ error: 'Request failed' }));
      throw new Error(error.error || 'Request failed');
    }

    return response.json();
  }

  private async publicRequest(endpoint: string, options: RequestInit = {}) {
    const url = `${this.baseURL}${endpoint}`;
    const headers = {
      'Content-Type': 'application/json',
      'X-Public-Browse': 'true',
      ...options.headers,
    };

    const response = await fetch(url, { ...options, headers });
    
    if (!response.ok) {
      const error = await response.json().catch(() => ({ error: 'Request failed' }));
      throw new Error(error.error || 'Request failed');
    }

    return response.json();
  }

  setToken(token: string) {
    this.token = token;
    if (typeof window !== 'undefined') {
      localStorage.setItem('token', token);
    }
  }

  clearToken() {
    this.token = null;
    if (typeof window !== 'undefined') {
      localStorage.removeItem('token');
    }
  }

  // Auth
  async register(data: any) {
    return this.request('/api/v2/register', {
      method: 'POST',
      body: JSON.stringify(data),
    }, true);
  }

  async login(data: any) {
    const response = await this.request('/auth/login', {
      method: 'POST',
      body: JSON.stringify(data),
    }, true);
    if (response.token) {
      this.setToken(response.token);
    }
    return response;
  }

  // Products (public access)
  async getProducts(params?: any) {
    const query = params ? `?${new URLSearchParams(params)}` : '';
    return this.publicRequest(`/api/v2/storeproducts${query}`);
  }

  async getStoreProducts(storeId: string, params?: any) {
    const query = params ? `?${new URLSearchParams(params)}` : '';
    return this.publicRequest(`/api/v2/stores/${storeId}/products${query}`);
  }

  // Cart
  async getCart() {
    return this.request('/api/v2/cart');
  }

  async addToCart(data: any) {
    return this.request('/api/v2/cart/add', {
      method: 'POST',
      body: JSON.stringify(data),
    }, true);
  }

  async removeFromCart(productId: string) {
    return this.request(`/api/v2/cart/remove/${productId}`, {
      method: 'DELETE',
    });
  }

  async clearCart() {
    return this.request('/api/v2/cart/clear', {
      method: 'DELETE',
    });
  }

  // Checkout
  async checkout(data: any) {
    return this.request('/api/v2/checkout', {
      method: 'POST',
      body: JSON.stringify(data),
    }, true);
  }

  // Stores (public access for GET)
  async getStores(params?: any) {
    const query = params ? `?${new URLSearchParams(params)}` : '';
    return this.publicRequest(`/api/v2/stores${query}`);
  }

  async createStore(data: any) {
    return this.request('/api/v2/stores', {
      method: 'POST',
      body: JSON.stringify(data),
    }, true);
  }

  // Categories
  async getCategories(storeId?: string) {
    const query = storeId ? `?store_id=${storeId}` : '';
    return this.publicRequest(`/api/v2/categories${query}`);
  }
}

export const api = new ApiClient(API_BASE_URL);
export default api;