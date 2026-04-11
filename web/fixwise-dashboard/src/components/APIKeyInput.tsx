import { useState, useCallback } from 'react';
import { api } from '../services/api';

interface APIKeyInputProps {
  onKeySaved: (maskedKey: string) => void;
  existingKeyMask?: string; // e.g., "sk-...abc123"
}

type ValidationState = 'idle' | 'validating' | 'valid' | 'invalid';

/**
 * BYOK (Bring Your Own Key) input component.
 * Allows users to securely input and validate their OpenAI API key.
 * The key is sent to the backend for encrypted storage — never stored client-side.
 */
export function APIKeyInput({ onKeySaved, existingKeyMask }: APIKeyInputProps) {
  const [apiKey, setApiKey] = useState('');
  const [validationState, setValidationState] = useState<ValidationState>('idle');
  const [errorMessage, setErrorMessage] = useState('');
  const [showKey, setShowKey] = useState(false);
  const [isEditing, setIsEditing] = useState(!existingKeyMask);

  const isValidFormat = (key: string): boolean => {
    // OpenAI keys start with "sk-" and are 40+ characters
    return /^sk-[a-zA-Z0-9_-]{40,}$/.test(key.trim());
  };

  const validateAndSave = useCallback(async () => {
    const trimmedKey = apiKey.trim();

    if (!isValidFormat(trimmedKey)) {
      setValidationState('invalid');
      setErrorMessage(
        'Invalid format. OpenAI API keys start with "sk-" and are at least 43 characters.'
      );
      return;
    }

    setValidationState('validating');
    setErrorMessage('');

    try {
      const data = await api.put('/api/settings/api-key', { apiKey: trimmedKey });
      setValidationState('valid');
      setApiKey('');
      setIsEditing(false);
      onKeySaved(data.maskedKey);
    } catch (err) {
      setValidationState('invalid');
      setErrorMessage(
        err instanceof Error ? err.message : 'Failed to validate key. Please try again.'
      );
    }
  }, [apiKey, onKeySaved]);

  const removeKey = useCallback(async () => {
    try {
      await api.del('/api/settings/api-key');
      setIsEditing(true);
      onKeySaved('');
    } catch {
      setErrorMessage('Failed to remove key.');
    }
  }, [onKeySaved]);

  // Existing key display
  if (!isEditing && existingKeyMask) {
    return (
      <div className="rounded-lg border border-gray-200 bg-white p-6 shadow-sm">
        <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
          <div className="min-w-0">
            <h3 className="text-sm font-medium text-gray-900">OpenAI API Key</h3>
            <div className="mt-1 flex flex-wrap items-center gap-2">
              <span className="inline-flex items-center rounded-md bg-green-50 px-2 py-1 text-xs font-medium text-green-700 ring-1 ring-green-600/20 ring-inset">
                Active
              </span>
              <code className="max-w-full truncate text-sm text-gray-500">{existingKeyMask}</code>
            </div>
          </div>
          <div className="flex flex-col gap-2 sm:flex-row">
            <button
              onClick={() => setIsEditing(true)}
              className="rounded-md bg-white px-3 py-2 text-sm font-semibold text-gray-900 ring-1 shadow-sm ring-gray-300 ring-inset hover:bg-gray-50"
            >
              Change
            </button>
            <button
              onClick={removeKey}
              className="rounded-md bg-white px-3 py-2 text-sm font-semibold text-red-600 ring-1 shadow-sm ring-red-300 ring-inset hover:bg-red-50"
            >
              Remove
            </button>
          </div>
        </div>
      </div>
    );
  }

  // Key input form
  return (
    <div className="rounded-lg border border-gray-200 bg-white p-6 shadow-sm">
      <h3 className="text-sm font-medium text-gray-900">OpenAI API Key</h3>
      <p className="mt-1 text-sm text-gray-500">
        Enter your OpenAI API key to use your own account. Your key is encrypted and
        stored securely — it is never logged or exposed.
      </p>

      <div className="mt-4">
        <div className="relative">
          <input
            type={showKey ? 'text' : 'password'}
            value={apiKey}
            onChange={(e) => {
              setApiKey(e.target.value);
              setValidationState('idle');
              setErrorMessage('');
            }}
            placeholder="sk-..."
            autoComplete="off"
            spellCheck={false}
            className={`block w-full rounded-md border-0 py-2 pl-3 pr-20 text-gray-900 ring-1 shadow-sm ring-inset placeholder:text-gray-400 focus:ring-2 focus:ring-inset sm:text-sm sm:leading-6 font-mono ${
              validationState === 'invalid'
                ? 'ring-red-300 focus:ring-red-500'
                : validationState === 'valid'
                  ? 'ring-green-300 focus:ring-green-500'
                  : 'ring-gray-300 focus:ring-indigo-600'
            }`}
          />
          <button
            type="button"
            onClick={() => setShowKey(!showKey)}
            className="absolute inset-y-0 right-0 flex items-center pr-3 text-gray-400 hover:text-gray-500"
            aria-label={showKey ? 'Hide key' : 'Show key'}
          >
            {showKey ? (
              <EyeSlashIcon className="h-5 w-5" />
            ) : (
              <EyeIcon className="h-5 w-5" />
            )}
          </button>
        </div>

        {errorMessage && (
          <p className="mt-2 text-sm text-red-600">{errorMessage}</p>
        )}

        {validationState === 'valid' && (
          <p className="mt-2 text-sm text-green-600">
            Key validated and saved successfully.
          </p>
        )}

        <div className="mt-4 flex flex-col gap-3 sm:flex-row">
          <button
            onClick={validateAndSave}
            disabled={!apiKey.trim() || validationState === 'validating'}
            className="rounded-md bg-indigo-600 px-4 py-2 text-sm font-semibold text-white shadow-sm hover:bg-indigo-500 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-indigo-600 disabled:cursor-not-allowed disabled:opacity-50"
          >
            {validationState === 'validating' ? (
              <span className="flex items-center gap-2">
                <Spinner /> Validating...
              </span>
            ) : (
              'Validate & Save'
            )}
          </button>

          {existingKeyMask && (
            <button
              onClick={() => {
                setIsEditing(false);
                setApiKey('');
                setErrorMessage('');
              }}
              className="rounded-md bg-white px-4 py-2 text-sm font-semibold text-gray-900 ring-1 shadow-sm ring-gray-300 ring-inset hover:bg-gray-50"
            >
              Cancel
            </button>
          )}
        </div>
      </div>

      <div className="mt-4 rounded-md bg-amber-50 p-3">
        <p className="text-xs text-amber-800">
          <strong>Security:</strong> Your API key is transmitted over TLS and encrypted
          with AES-256 before storage. It is only decrypted in-memory during active
          sessions. We never log or share your key.
        </p>
      </div>
    </div>
  );
}

// MARK: - Helper Components

function Spinner() {
  return (
    <svg
      className="h-4 w-4 animate-spin text-white"
      xmlns="http://www.w3.org/2000/svg"
      fill="none"
      viewBox="0 0 24 24"
    >
      <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
      <path
        className="opacity-75"
        fill="currentColor"
        d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"
      />
    </svg>
  );
}

function EyeIcon({ className }: { className?: string }) {
  return (
    <svg className={className} fill="none" viewBox="0 0 24 24" strokeWidth={1.5} stroke="currentColor">
      <path strokeLinecap="round" strokeLinejoin="round" d="M2.036 12.322a1.012 1.012 0 010-.639C3.423 7.51 7.36 4.5 12 4.5c4.638 0 8.573 3.007 9.963 7.178.07.207.07.431 0 .639C20.577 16.49 16.64 19.5 12 19.5c-4.638 0-8.573-3.007-9.963-7.178z" />
      <path strokeLinecap="round" strokeLinejoin="round" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z" />
    </svg>
  );
}

function EyeSlashIcon({ className }: { className?: string }) {
  return (
    <svg className={className} fill="none" viewBox="0 0 24 24" strokeWidth={1.5} stroke="currentColor">
      <path strokeLinecap="round" strokeLinejoin="round" d="M3.98 8.223A10.477 10.477 0 001.934 12c1.292 4.338 5.31 7.5 10.066 7.5.993 0 1.953-.138 2.863-.395M6.228 6.228A10.45 10.45 0 0112 4.5c4.756 0 8.773 3.162 10.065 7.498a10.523 10.523 0 01-4.293 5.774M6.228 6.228L3 3m3.228 3.228l3.65 3.65m7.894 7.894L21 21m-3.228-3.228l-3.65-3.65m0 0a3 3 0 10-4.243-4.243m4.242 4.242L9.88 9.88" />
    </svg>
  );
}
