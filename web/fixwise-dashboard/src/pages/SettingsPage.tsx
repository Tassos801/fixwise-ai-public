import { useCallback, useEffect, useState } from 'react';
import { useAuth } from '../services/auth';
import { APIKeyInput } from '../components/APIKeyInput';

export function SettingsPage() {
  const { user, refreshUser } = useAuth();
  const [apiKeyMask, setApiKeyMask] = useState<string | undefined>(user?.apiKeyMask ?? undefined);

  useEffect(() => {
    setApiKeyMask(user?.apiKeyMask ?? undefined);
  }, [user?.apiKeyMask]);

  const handleKeySaved = useCallback(
    (mask: string) => {
      setApiKeyMask(mask || undefined);
      refreshUser();
    },
    [refreshUser],
  );

  return (
    <div>
      <div className="mb-8">
        <h1 className="text-2xl font-bold text-gray-900">Settings</h1>
        <p className="mt-1 text-sm text-gray-500">
          Manage your account access and BYOK key for the private beta.
        </p>
      </div>

      <div className="space-y-6">
        {/* Profile Section */}
        <section className="rounded-xl bg-white p-6 shadow-sm ring-1 ring-gray-200">
          <h2 className="mb-4 text-lg font-semibold text-gray-900">Profile</h2>
          <dl className="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <div>
              <dt className="text-sm text-gray-500">Email</dt>
              <dd className="mt-1 text-sm font-medium text-gray-900">{user?.email}</dd>
            </div>
            <div>
              <dt className="text-sm text-gray-500">Display Name</dt>
              <dd className="mt-1 text-sm font-medium text-gray-900">
                {user?.displayName || <span className="text-gray-400">Not set</span>}
              </dd>
            </div>
          </dl>
        </section>

        {/* API Key Section */}
        <section>
          <h2 className="text-lg font-semibold text-gray-900 mb-4">OpenAI API Key (BYOK)</h2>
          <APIKeyInput
            onKeySaved={handleKeySaved}
            existingKeyMask={apiKeyMask}
          />
        </section>
      </div>
    </div>
  );
}
