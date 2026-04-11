import { useCallback, useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { api } from '../services/api';
import { useAuth } from '../services/auth';

interface Session {
  id: string;
  status: string;
  stepCount: number;
  startedAt: string;
  endedAt: string | null;
  reportUrl: string | null;
}

export function DashboardPage() {
  const { user } = useAuth();
  const [sessions, setSessions] = useState<Session[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState('');

  const fetchSessions = useCallback(async () => {
    try {
      const data = await api.get('/api/sessions');
      setSessions(data.sessions);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load sessions');
    } finally {
      setIsLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchSessions();
  }, [fetchSessions]);

  return (
    <div>
      {/* Header */}
      <div className="mb-8">
        <h1 className="text-2xl font-bold text-gray-900">Dashboard</h1>
        <p className="mt-1 text-sm text-gray-500">
          Welcome back{user?.displayName ? `, ${user.displayName}` : ''}. Here are your recent sessions.
        </p>
      </div>

      {/* Stats Cards */}
      <div className="mb-8 grid grid-cols-1 gap-4 sm:grid-cols-3">
        <StatCard
          label="Total Sessions"
          value={sessions.length}
          color="bg-fixwise-orange"
        />
        <StatCard
          label="Completed"
          value={sessions.filter((s) => s.status === 'completed').length}
          color="bg-fixwise-teal"
        />
        <StatCard
          label="Total Steps"
          value={sessions.reduce((acc, s) => acc + s.stepCount, 0)}
          color="bg-fixwise-blue"
        />
      </div>

      {/* Sessions List */}
      <div className="rounded-xl bg-white shadow-sm ring-1 ring-gray-200">
        <div className="border-b border-gray-200 px-4 py-4 sm:px-6">
          <h2 className="text-lg font-semibold text-gray-900">Session History</h2>
        </div>

        {isLoading ? (
          <div className="flex items-center justify-center py-12">
            <div className="h-6 w-6 animate-spin rounded-full border-2 border-fixwise-orange border-t-transparent" />
          </div>
        ) : error ? (
          <div className="px-6 py-8 text-center text-sm text-red-600">{error}</div>
        ) : sessions.length === 0 ? (
          <div className="px-6 py-12 text-center">
            <p className="text-sm text-gray-500">No sessions yet.</p>
            <p className="mt-1 text-xs text-gray-400">
              Open the FixWise iOS app and start your first guided session.
            </p>
          </div>
        ) : (
          <ul className="divide-y divide-gray-100">
            {sessions.map((session) => (
              <li key={session.id}>
                <Link
                  to={`/sessions/${session.id}`}
                  className="flex flex-col gap-3 px-4 py-4 transition-colors hover:bg-gray-50 sm:flex-row sm:items-center sm:justify-between sm:px-6"
                >
                  <div className="flex min-w-0 items-start gap-3 sm:items-center sm:gap-4">
                    <StatusBadge status={session.status} />
                    <div className="min-w-0">
                      <p className="truncate text-sm font-medium text-gray-900">
                        Session {session.id.slice(0, 8)}
                      </p>
                      <p className="mt-0.5 text-xs text-gray-500">
                        {formatDate(session.startedAt)} &middot; {session.stepCount} steps
                      </p>
                    </div>
                  </div>
                  <div className="flex items-center justify-between gap-3 sm:justify-end">
                    {session.status === 'completed' && (
                      <span className="text-xs text-fixwise-orange font-medium">
                        View Report
                      </span>
                    )}
                    <ChevronRight />
                  </div>
                </Link>
              </li>
            ))}
          </ul>
        )}
      </div>
    </div>
  );
}

function StatCard({ label, value, color }: { label: string; value: number; color: string }) {
  return (
    <div className="rounded-xl bg-white p-5 shadow-sm ring-1 ring-gray-200">
      <div className="flex items-center gap-3">
        <div className={`h-2 w-2 rounded-full ${color}`} />
        <span className="text-sm text-gray-500">{label}</span>
      </div>
      <p className="mt-2 text-3xl font-bold text-gray-900">{value}</p>
    </div>
  );
}

function StatusBadge({ status }: { status: string }) {
  const styles =
    status === 'completed'
      ? 'bg-green-50 text-green-700 ring-green-600/20'
      : status === 'active'
        ? 'bg-blue-50 text-blue-700 ring-blue-600/20'
        : 'bg-gray-50 text-gray-600 ring-gray-500/20';

  return (
    <span className={`inline-flex items-center rounded-md px-2 py-1 text-xs font-medium ring-1 ring-inset ${styles}`}>
      {status}
    </span>
  );
}

function ChevronRight() {
  return (
    <svg className="h-4 w-4 text-gray-400" fill="none" viewBox="0 0 24 24" strokeWidth={2} stroke="currentColor">
      <path strokeLinecap="round" strokeLinejoin="round" d="M8.25 4.5l7.5 7.5-7.5 7.5" />
    </svg>
  );
}

function formatDate(isoString: string): string {
  try {
    return new Date(isoString).toLocaleDateString('en-US', {
      month: 'short',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit',
    });
  } catch {
    return isoString;
  }
}
