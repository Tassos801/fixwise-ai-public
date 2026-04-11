import { useState } from 'react';
import { Link, Outlet, useLocation } from 'react-router-dom';
import { useAuth } from '../services/auth';

const NAV_ITEMS = [
  { path: '/', label: 'Dashboard', icon: '📊' },
  { path: '/settings', label: 'Settings', icon: '⚙️' },
];

export function Layout() {
  const { user, logout } = useAuth();
  const location = useLocation();
  const [isMenuOpen, setIsMenuOpen] = useState(false);

  return (
    <div className="min-h-screen bg-gray-50">
      {/* Top Navigation */}
      <nav className="border-b border-gray-200 bg-white shadow-sm">
        <div className="mx-auto max-w-7xl px-4 py-3 sm:px-6 lg:px-8">
          <div className="flex items-center justify-between gap-3">
            {/* Logo */}
            <Link to="/" className="flex min-w-0 items-center gap-2" onClick={() => setIsMenuOpen(false)}>
              <div className="flex h-8 w-8 flex-shrink-0 items-center justify-center rounded-lg bg-fixwise-orange text-sm font-bold text-white">
                FW
              </div>
              <span className="truncate text-lg font-semibold text-fixwise-dark">FixWise AI</span>
            </Link>

            <div className="hidden items-center gap-6 md:flex">
              {NAV_ITEMS.map(({ path, label, icon }) => (
                <Link
                  key={path}
                  to={path}
                  className={`flex items-center gap-1.5 text-sm font-medium transition-colors ${
                    location.pathname === path
                      ? 'text-fixwise-orange'
                      : 'text-gray-600 hover:text-gray-900'
                  }`}
                >
                  <span>{icon}</span>
                  {label}
                </Link>
              ))}

              <div className="flex items-center gap-3 border-l border-gray-200 pl-6">
                <div className="text-right">
                  <p className="text-sm font-medium text-gray-900">
                    {user?.displayName || user?.email}
                  </p>
                  <p className="text-xs text-gray-500 capitalize">{user?.tier} plan</p>
                </div>
                <button
                  onClick={logout}
                  className="rounded-md bg-gray-100 px-3 py-1.5 text-xs font-medium text-gray-600 transition-colors hover:bg-gray-200"
                >
                  Sign out
                </button>
              </div>
            </div>

            <button
              type="button"
              className="inline-flex items-center justify-center rounded-lg border border-gray-200 px-3 py-2 text-sm font-medium text-gray-700 md:hidden"
              onClick={() => setIsMenuOpen((open) => !open)}
              aria-expanded={isMenuOpen}
              aria-controls="mobile-nav"
            >
              <span className="sr-only">Toggle navigation menu</span>
              <MenuIcon />
            </button>
          </div>

          {isMenuOpen && (
            <div
              id="mobile-nav"
              className="mt-3 rounded-2xl border border-gray-200 bg-white p-3 shadow-sm md:hidden"
            >
              <div className="grid gap-2">
                {NAV_ITEMS.map(({ path, label, icon }) => (
                  <Link
                    key={path}
                    to={path}
                    onClick={() => setIsMenuOpen(false)}
                    className={`flex items-center gap-3 rounded-xl px-3 py-3 text-sm font-medium ${
                      location.pathname === path
                        ? 'bg-orange-50 text-fixwise-orange'
                        : 'text-gray-700 hover:bg-gray-50'
                    }`}
                  >
                    <span className="text-base">{icon}</span>
                    {label}
                  </Link>
                ))}
              </div>

              <div className="mt-4 border-t border-gray-100 pt-4">
                <p className="text-sm font-medium text-gray-900">
                  {user?.displayName || user?.email}
                </p>
                <p className="mt-1 text-xs text-gray-500 capitalize">{user?.tier} plan</p>
                <button
                  onClick={() => {
                    setIsMenuOpen(false);
                    logout();
                  }}
                  className="mt-3 w-full rounded-xl bg-gray-100 px-4 py-2.5 text-sm font-medium text-gray-700"
                >
                  Sign out
                </button>
              </div>
            </div>
          )}
        </div>
      </nav>

      {/* Page Content */}
      <main className="mx-auto max-w-7xl px-4 py-8 sm:px-6 lg:px-8">
        <Outlet />
      </main>
    </div>
  );
}

function MenuIcon() {
  return (
    <svg className="h-5 w-5 text-gray-600" fill="none" viewBox="0 0 24 24" strokeWidth={2} stroke="currentColor">
      <path strokeLinecap="round" strokeLinejoin="round" d="M4 6h16M4 12h16M4 18h16" />
    </svg>
  );
}
