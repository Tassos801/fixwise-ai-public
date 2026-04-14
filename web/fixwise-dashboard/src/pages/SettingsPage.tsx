import { useCallback, useState } from 'react';
import { useAuth } from '../services/auth';
import { APIKeyInput } from '../components/APIKeyInput';

type ProviderValue = 'openai' | 'gemma';

function normalizeProvider(provider?: string | null): ProviderValue | null {
  if (provider === 'openai' || provider === 'gemma') {
    return provider;
  }
  return null;
}

function providerLabel(provider?: string | null): string {
  const normalized = normalizeProvider(provider);
  if (normalized === 'gemma') {
    return 'Gemma / Google AI Studio';
  }
  if (normalized === 'openai') {
    return 'OpenAI';
  }
  return 'Not set';
}

export function SettingsPage() {
  const { user, refreshUser } = useAuth();
  const [localMaskOverride, setLocalMaskOverride] = useState<string | null>(null);
  const [localProviderOverride, setLocalProviderOverride] = useState<ProviderValue | null>(null);
  const apiKeyMask = localMaskOverride ?? user?.apiKeyMask ?? undefined;
  const savedProvider = localProviderOverride ?? normalizeProvider(
    user?.provider ?? user?.apiProvider ?? user?.aiProvider ?? user?.apiKeyProvider,
  );

  const handleKeySaved = useCallback(
    (mask: string, provider?: ProviderValue | null) => {
      setLocalMaskOverride(mask || null);
      setLocalProviderOverride(provider ?? null);
      refreshUser();
    },
    [refreshUser],
  );

  return (
    <div>
      <div className="mb-8">
        <h1 className="text-2xl font-bold text-gray-900">Settings</h1>
        <p className="mt-1 text-sm text-gray-500">
          Manage your account access and the provider key used for live AI in the private beta.
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
            <div>
              <dt className="text-sm text-gray-500">AI Provider</dt>
              <dd className="mt-1 text-sm font-medium text-gray-900">
                {providerLabel(savedProvider)}
              </dd>
            </div>
          </dl>
        </section>

        {/* API Key Section */}
        <section>
          <h2 className="text-lg font-semibold text-gray-900 mb-4">AI Provider Key (BYOK)</h2>
          <APIKeyInput
            onKeySaved={handleKeySaved}
            existingKeyMask={apiKeyMask}
            existingProvider={savedProvider}
          />
        </section>
      </div>
    </div>
  );
}
