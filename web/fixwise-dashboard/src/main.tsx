import React from 'react';
import ReactDOM from 'react-dom/client';
import { BrowserRouter } from 'react-router-dom';
import { AuthProvider } from './services/auth';
import { App } from './App';
import './index.css';

const baseUrl = import.meta.env.VITE_API_BASE_URL?.trim();

if (baseUrl) {
  console.info(`[FixWise] Dashboard API base URL: ${baseUrl}`);
}

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <BrowserRouter>
      <AuthProvider>
        <App />
      </AuthProvider>
    </BrowserRouter>
  </React.StrictMode>,
);
