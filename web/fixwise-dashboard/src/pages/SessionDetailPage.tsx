import { useCallback, useEffect, useMemo, useState } from 'react';
import { useParams, Link } from 'react-router-dom';
import { api } from '../services/api';
import {
  formatConfidenceLabel,
  resolveSessionNextAction,
  resolveSessionSummary,
  resolveStepThumbnail,
  type SessionStepItem,
  type SessionDetailItem,
} from '../types/sessions';

export function SessionDetailPage() {
  const { sessionId } = useParams<{ sessionId: string }>();
  const [session, setSession] = useState<SessionDetailItem | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState('');
  const [isDownloading, setIsDownloading] = useState(false);

  const fetchSession = useCallback(async () => {
    if (!sessionId) return;
    try {
      const data = await api.get(`/api/sessions/${sessionId}`);
      setSession(data);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load session');
    } finally {
      setIsLoading(false);
    }
  }, [sessionId]);

  const handleDownloadReport = async () => {
    if (!sessionId || !session) return;

    setIsDownloading(true);
    try {
      const blob = await api.downloadReport(sessionId);
      const url = URL.createObjectURL(blob);
      const anchor = document.createElement('a');
      anchor.href = url;
      anchor.download = `fixwise-report-${session.id.slice(0, 8)}.pdf`;
      document.body.appendChild(anchor);
      anchor.click();
      anchor.remove();
      URL.revokeObjectURL(url);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to download report');
    } finally {
      setIsDownloading(false);
    }
  };

  useEffect(() => {
    fetchSession();
  }, [fetchSession]);

  const stepThumbnails = useMemo(
    () =>
      session?.steps
        .map((step) => {
          const thumbnail = resolveStepThumbnail(step);
          return thumbnail ? { step, thumbnail } : null;
        })
        .filter((entry): entry is { step: SessionStepItem; thumbnail: string } => entry !== null) ?? [],
    [session],
  );

  if (isLoading) {
    return (
      <div className="flex items-center justify-center py-20">
        <div className="h-6 w-6 animate-spin rounded-full border-2 border-fixwise-orange border-t-transparent" />
      </div>
    );
  }

  if (error || !session) {
    return (
      <div className="py-12 text-center">
        <p className="text-red-600">{error || 'Session not found'}</p>
        <Link to="/" className="mt-4 inline-block text-sm text-fixwise-orange hover:underline">
          Back to Dashboard
        </Link>
      </div>
    );
  }

  const sessionSummary = resolveSessionSummary(session);
  const sessionNextAction = resolveSessionNextAction(session);
  const confidenceLabel = formatConfidenceLabel(session.confidence);

  return (
    <div>
      {/* Breadcrumb */}
      <nav className="mb-6 text-sm text-gray-500">
        <Link to="/" className="hover:text-gray-700">Dashboard</Link>
        <span className="mx-2">/</span>
        <span className="text-gray-900">Session {session.id.slice(0, 8)}</span>
      </nav>

      {/* Session Header */}
      <div className="mb-8 flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
        <div className="min-w-0">
          <h1 className="truncate text-2xl font-bold text-gray-900">
            Session {session.id.slice(0, 8)}
          </h1>
          <div className="mt-2 flex flex-wrap items-center gap-x-4 gap-y-2 text-sm text-gray-500">
            <span>Started: {formatDateTime(session.startedAt)}</span>
            {session.endedAt && <span>Ended: {formatDateTime(session.endedAt)}</span>}
            <span>{session.stepCount} steps</span>
            <StatusPill status={session.status} />
          </div>
        </div>

        {session.status === 'completed' && (
          <button
            type="button"
            onClick={handleDownloadReport}
            disabled={isDownloading}
            className="flex w-full items-center justify-center gap-2 rounded-lg bg-fixwise-orange px-4 py-2 text-sm font-semibold text-white shadow-sm hover:bg-orange-600 disabled:cursor-not-allowed disabled:opacity-60 sm:w-auto"
          >
            <DownloadIcon />
            {isDownloading ? 'Preparing...' : 'Download Report'}
          </button>
        )}
      </div>

      <div className="mb-8 grid grid-cols-1 gap-4 lg:grid-cols-3">
        <InfoCard
          label="Session summary"
          value={sessionSummary ?? 'A summary will appear here when the backend provides one.'}
          hint="What the assistant understands about this session"
        />
        <InfoCard
          label="Next action"
          value={sessionNextAction ?? 'A next step will be suggested when available.'}
          hint="Use this to keep the flow moving"
        />
        <InfoCard
          label="Confidence"
          value={confidenceLabel ?? 'Not reported yet'}
          hint="Backend confidence for the latest guidance"
        />
      </div>

      <section className="mb-8 rounded-xl bg-white shadow-sm ring-1 ring-gray-200">
        <div className="border-b border-gray-200 px-4 py-4 sm:px-6">
          <h2 className="text-lg font-semibold text-gray-900">Frame previews</h2>
        </div>
        <div className="px-4 py-4 sm:px-6">
          <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-4">
            {stepThumbnails.length > 0 ? (
              stepThumbnails.map(({ step, thumbnail }) => (
                <div key={step.stepNumber} className="overflow-hidden rounded-2xl border border-gray-200 bg-gray-50">
                  <div className="aspect-square bg-gray-100">
                    <img src={thumbnail} alt={`Step ${step.stepNumber} frame preview`} className="h-full w-full object-cover" loading="lazy" />
                  </div>
                  <div className="px-3 py-2 text-xs text-gray-500">
                    Step {step.stepNumber}
                  </div>
                </div>
              ))
            ) : (
              <div className="col-span-full rounded-2xl border border-dashed border-gray-200 bg-gray-50 px-4 py-6 text-center text-sm text-gray-500">
                Frame previews will appear here if the backend includes thumbnail fields.
              </div>
            )}
          </div>
        </div>
      </section>

      {/* Steps Timeline */}
      <div className="rounded-xl bg-white shadow-sm ring-1 ring-gray-200">
        <div className="border-b border-gray-200 px-4 py-4 sm:px-6">
          <h2 className="text-lg font-semibold text-gray-900">Steps</h2>
        </div>

        {session.steps.length === 0 ? (
          <div className="px-6 py-12 text-center text-sm text-gray-500">
            No steps recorded for this session.
          </div>
        ) : (
          <div className="divide-y divide-gray-100">
            {session.steps.map((step) => (
              <div key={step.stepNumber} className="px-4 py-5 sm:px-6">
                <div className="flex items-start gap-3 sm:gap-4">
                  {/* Step Number Circle */}
                  <div className="flex h-8 w-8 flex-shrink-0 items-center justify-center rounded-full bg-fixwise-orange/10 text-sm font-bold text-fixwise-orange">
                    {step.stepNumber}
                  </div>

                  <div className="flex-1">
                    <p className="text-sm leading-relaxed text-gray-900">{step.text}</p>

                    {step.nextAction && (
                      <div className="mt-2 rounded-lg bg-orange-50 px-3 py-2 text-xs text-fixwise-orange ring-1 ring-inset ring-orange-200">
                        Next step: {step.nextAction}
                      </div>
                    )}

                    {step.followUpPrompts && step.followUpPrompts.length > 0 && (
                      <div className="mt-2 flex flex-wrap gap-2">
                        {step.followUpPrompts.slice(0, 3).map((prompt) => (
                          <span key={prompt} className="inline-flex rounded-full bg-gray-100 px-2.5 py-1 text-xs text-gray-600 ring-1 ring-inset ring-gray-200">
                            {prompt}
                          </span>
                        ))}
                      </div>
                    )}

                    {step.safetyWarning && (
                      <div className="mt-2 rounded-lg bg-yellow-50 px-3 py-2 text-xs text-yellow-800 ring-1 ring-inset ring-yellow-200">
                        Warning: {step.safetyWarning}
                      </div>
                    )}

                    <div className="mt-2 flex flex-wrap items-center gap-x-3 gap-y-2 text-xs text-gray-400">
                      <span>{formatTime(step.createdAt)}</span>
                      {step.hasFrame && (
                        <span className="inline-flex items-center gap-1">
                          <CameraIcon />
                          Frame captured
                        </span>
                      )}
                    </div>
                  </div>
                </div>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

function InfoCard({ label, value, hint }: { label: string; value: string; hint: string }) {
  return (
    <div className="rounded-xl bg-white p-5 shadow-sm ring-1 ring-gray-200">
      <p className="text-xs font-semibold uppercase tracking-wide text-gray-500">{label}</p>
      <p className="mt-2 text-sm font-medium text-gray-900">{value}</p>
      <p className="mt-1 text-xs text-gray-400">{hint}</p>
    </div>
  );
}

function StatusPill({ status }: { status: string }) {
  const color =
    status === 'completed'
      ? 'bg-green-100 text-green-700'
      : status === 'active'
        ? 'bg-blue-100 text-blue-700'
        : 'bg-gray-100 text-gray-600';

  return (
    <span className={`rounded-full px-2.5 py-0.5 text-xs font-medium ${color}`}>
      {status}
    </span>
  );
}

function DownloadIcon() {
  return (
    <svg className="h-4 w-4" fill="none" viewBox="0 0 24 24" strokeWidth={2} stroke="currentColor">
      <path strokeLinecap="round" strokeLinejoin="round" d="M3 16.5v2.25A2.25 2.25 0 005.25 21h13.5A2.25 2.25 0 0021 18.75V16.5M16.5 12L12 16.5m0 0L7.5 12m4.5 4.5V3" />
    </svg>
  );
}

function CameraIcon() {
  return (
    <svg className="h-3 w-3" fill="none" viewBox="0 0 24 24" strokeWidth={2} stroke="currentColor">
      <path strokeLinecap="round" strokeLinejoin="round" d="M6.827 6.175A2.31 2.31 0 015.186 7.23c-.38.054-.757.112-1.134.175C2.999 7.58 2.25 8.507 2.25 9.574V18a2.25 2.25 0 002.25 2.25h15A2.25 2.25 0 0021.75 18V9.574c0-1.067-.75-1.994-1.802-2.169a47.865 47.865 0 00-1.134-.175 2.31 2.31 0 01-1.64-1.055l-.822-1.316a2.192 2.192 0 00-1.736-1.039 48.774 48.774 0 00-5.232 0 2.192 2.192 0 00-1.736 1.039l-.821 1.316z" />
      <path strokeLinecap="round" strokeLinejoin="round" d="M16.5 12.75a4.5 4.5 0 11-9 0 4.5 4.5 0 019 0z" />
    </svg>
  );
}

function formatDateTime(iso: string): string {
  try {
    return new Date(iso).toLocaleString('en-US', {
      month: 'short', day: 'numeric', year: 'numeric',
      hour: '2-digit', minute: '2-digit',
    });
  } catch { return iso; }
}

function formatTime(iso: string): string {
  try {
    return new Date(iso).toLocaleTimeString('en-US', {
      hour: '2-digit', minute: '2-digit', second: '2-digit',
    });
  } catch { return iso; }
}
