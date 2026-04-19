import { useMemo, useState } from 'react';
import {
  resolveSessionNextAction,
  resolveSessionSummary,
  resolveSessionThumbnail,
  type SessionListItem,
} from '../types/sessions';

interface SessionAnalyticsProps {
  sessions: SessionListItem[];
  onViewAll?: () => void;
}

const DAY_NAMES = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];

function getHeatmapColor(count: number): string {
  if (count >= 3) return 'bg-orange-600';
  if (count >= 2) return 'bg-orange-400';
  if (count >= 1) return 'bg-orange-200';
  return 'bg-gray-100';
}

function timeAgo(dateStr: string): string {
  const now = Date.now();
  const then = new Date(dateStr).getTime();
  const diffMs = now - then;
  const diffMin = Math.floor(diffMs / 60000);
  if (diffMin < 1) return 'just now';
  if (diffMin < 60) return `${diffMin}m ago`;
  const diffHrs = Math.floor(diffMin / 60);
  if (diffHrs < 24) return `${diffHrs}h ago`;
  const diffDays = Math.floor(diffHrs / 24);
  if (diffDays === 1) return '1d ago';
  if (diffDays < 30) return `${diffDays}d ago`;
  return `${Math.floor(diffDays / 30)}mo ago`;
}

function formatDateShort(date: Date): string {
  return date.toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
}

export function SessionAnalytics({ sessions, onViewAll }: SessionAnalyticsProps) {
  const [hoveredDay, setHoveredDay] = useState<number | null>(null);

  const heatmapData = useMemo(() => {
    const today = new Date();
    today.setHours(23, 59, 59, 999);
    const days: { date: Date; count: number }[] = [];

    for (let i = 29; i >= 0; i--) {
      const d = new Date(today);
      d.setDate(d.getDate() - i);
      d.setHours(0, 0, 0, 0);
      days.push({ date: new Date(d), count: 0 });
    }

    for (const session of sessions) {
      const sessionDate = new Date(session.startedAt);
      sessionDate.setHours(0, 0, 0, 0);
      const sessionTime = sessionDate.getTime();

      for (const day of days) {
        const dayStart = new Date(day.date);
        dayStart.setHours(0, 0, 0, 0);
        if (dayStart.getTime() === sessionTime) {
          day.count++;
          break;
        }
      }
    }

    return days;
  }, [sessions]);

  const quickStats = useMemo(() => {
    const now = new Date();
    const thisMonthStart = new Date(now.getFullYear(), now.getMonth(), 1);
    const lastMonthStart = new Date(now.getFullYear(), now.getMonth() - 1, 1);
    const lastMonthEnd = new Date(now.getFullYear(), now.getMonth(), 0, 23, 59, 59, 999);

    const thisMonthSessions = sessions.filter(
      (s) => new Date(s.startedAt) >= thisMonthStart,
    );
    const lastMonthSessions = sessions.filter((s) => {
      const d = new Date(s.startedAt);
      return d >= lastMonthStart && d <= lastMonthEnd;
    });

    const avgSteps =
      sessions.length > 0
        ? Math.round(sessions.reduce((sum, s) => sum + s.stepCount, 0) / sessions.length)
        : 0;

    // Most active day of week
    const dayCounts = [0, 0, 0, 0, 0, 0, 0];
    for (const s of sessions) {
      const dayOfWeek = new Date(s.startedAt).getDay();
      dayCounts[dayOfWeek] = (dayCounts[dayOfWeek] ?? 0) + 1;
    }
    const maxDayCount = Math.max(...dayCounts);
    const mostActiveDay =
      maxDayCount > 0 ? DAY_NAMES[dayCounts.indexOf(maxDayCount)] : '--';

    const thisCount = thisMonthSessions.length;
    const lastCount = lastMonthSessions.length;
    const monthDiff = thisCount - lastCount;

    return { avgSteps, mostActiveDay, thisCount, lastCount, monthDiff };
  }, [sessions]);

  const recentSessions = useMemo(() => {
    return [...sessions]
      .sort((a, b) => new Date(b.startedAt).getTime() - new Date(a.startedAt).getTime())
      .slice(0, 5);
  }, [sessions]);

  return (
    <div className="mb-8 space-y-6">
      {/* Activity Heatmap */}
      <div className="rounded-xl bg-white p-5 shadow-sm ring-1 ring-gray-200">
        <p className="mb-3 text-sm font-medium text-gray-500">Last 30 Days</p>
        <div className="relative flex gap-1">
          {heatmapData.map((day, idx) => (
            <div
              key={idx}
              className="relative"
              onMouseEnter={() => setHoveredDay(idx)}
              onMouseLeave={() => setHoveredDay(null)}
            >
              <div
                className={`h-5 w-5 rounded-sm ${getHeatmapColor(day.count)} transition-colors`}
              />
              {hoveredDay === idx && (
                <div className="absolute bottom-full left-1/2 z-10 mb-2 -translate-x-1/2 whitespace-nowrap rounded-md bg-gray-900 px-2.5 py-1.5 text-xs text-white shadow-lg">
                  <span className="font-medium">{formatDateShort(day.date)}</span>
                  <span className="ml-1.5 text-gray-300">
                    {day.count} session{day.count !== 1 ? 's' : ''}
                  </span>
                  <div className="absolute left-1/2 top-full -translate-x-1/2 border-4 border-transparent border-t-gray-900" />
                </div>
              )}
            </div>
          ))}
        </div>
        <div className="mt-2 flex items-center gap-1.5 text-[10px] text-gray-400">
          <span>Less</span>
          <div className="h-3 w-3 rounded-sm bg-gray-100" />
          <div className="h-3 w-3 rounded-sm bg-orange-200" />
          <div className="h-3 w-3 rounded-sm bg-orange-400" />
          <div className="h-3 w-3 rounded-sm bg-orange-600" />
          <span>More</span>
        </div>
      </div>

      {/* Quick Stats Row */}
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
        <div className="rounded-xl bg-white p-5 shadow-sm ring-1 ring-gray-200">
          <p className="text-sm text-gray-500">Avg Steps / Session</p>
          <p className="mt-1 text-2xl font-bold text-gray-900">{quickStats.avgSteps}</p>
        </div>
        <div className="rounded-xl bg-white p-5 shadow-sm ring-1 ring-gray-200">
          <p className="text-sm text-gray-500">Most Active Day</p>
          <p className="mt-1 text-2xl font-bold text-gray-900">{quickStats.mostActiveDay}</p>
        </div>
        <div className="rounded-xl bg-white p-5 shadow-sm ring-1 ring-gray-200">
          <p className="text-sm text-gray-500">This Month vs Last</p>
          <div className="mt-1 flex items-baseline gap-2">
            <span className="text-2xl font-bold text-gray-900">{quickStats.thisCount}</span>
            <span className="text-sm text-gray-400">vs {quickStats.lastCount}</span>
            {quickStats.monthDiff !== 0 && (
              <span
                className={`flex items-center text-sm font-medium ${
                  quickStats.monthDiff > 0 ? 'text-green-600' : 'text-red-500'
                }`}
              >
                {quickStats.monthDiff > 0 ? (
                  <svg className="mr-0.5 h-3.5 w-3.5" fill="none" viewBox="0 0 24 24" strokeWidth={2.5} stroke="currentColor">
                    <path strokeLinecap="round" strokeLinejoin="round" d="M4.5 19.5l7.5-7.5 7.5 7.5" />
                  </svg>
                ) : (
                  <svg className="mr-0.5 h-3.5 w-3.5" fill="none" viewBox="0 0 24 24" strokeWidth={2.5} stroke="currentColor">
                    <path strokeLinecap="round" strokeLinejoin="round" d="M19.5 4.5l-7.5 7.5-7.5-7.5" />
                  </svg>
                )}
                {Math.abs(quickStats.monthDiff)}
              </span>
            )}
          </div>
        </div>
      </div>

      {/* Recent Activity Feed */}
      <div className="rounded-xl bg-white shadow-sm ring-1 ring-gray-200">
        <div className="flex items-center justify-between border-b border-gray-200 px-6 py-4">
          <h3 className="text-sm font-semibold text-gray-900">Recent Activity</h3>
          {onViewAll && (
            <button
              onClick={onViewAll}
              className="text-xs font-medium text-fixwise-orange hover:text-orange-700 transition-colors"
            >
              View All
            </button>
          )}
        </div>
        {recentSessions.length === 0 ? (
          <div className="px-6 py-8 text-center text-sm text-gray-400">No sessions yet</div>
        ) : (
          <ul className="divide-y divide-gray-100">
            {recentSessions.map((session) => (
              <li key={session.id} className="flex items-start gap-3 px-4 py-3 sm:px-6">
                <SessionMiniPreview session={session} />
                <div className="min-w-0 flex-1">
                  <div className="flex items-center gap-2">
                    <StatusDot status={session.status} />
                    <div className="min-w-0">
                      <p className="truncate text-sm font-medium text-gray-900">
                        {resolveSessionSummary(session) ?? `${session.id.slice(0, 8)}...`}
                      </p>
                      <p className="text-xs text-gray-400">{timeAgo(session.startedAt)} &middot; {session.stepCount} steps</p>
                    </div>
                  </div>
                  {resolveSessionNextAction(session) && (
                    <p className="mt-1 max-h-10 overflow-hidden text-xs text-gray-500">
                      Next: {resolveSessionNextAction(session)}
                    </p>
                  )}
                </div>
                <div className="flex flex-col items-end gap-2">
                  <span
                    className={`inline-flex items-center rounded-md px-2 py-0.5 text-[10px] font-medium ring-1 ring-inset ${
                      session.status === 'completed'
                        ? 'bg-green-50 text-green-700 ring-green-600/20'
                        : session.status === 'active'
                          ? 'bg-blue-50 text-blue-700 ring-blue-600/20'
                          : 'bg-gray-50 text-gray-600 ring-gray-500/20'
                    }`}
                  >
                    {session.status}
                  </span>
                </div>
              </li>
            ))}
          </ul>
        )}
      </div>
    </div>
  );
}

function SessionMiniPreview({ session }: { session: SessionListItem }) {
  const thumbnail = resolveSessionThumbnail(session);

  if (thumbnail) {
    return (
      <div className="h-12 w-12 flex-shrink-0 overflow-hidden rounded-xl bg-gray-100 ring-1 ring-gray-200">
        <img src={thumbnail} alt="Recent session preview" className="h-full w-full object-cover" loading="lazy" />
      </div>
    );
  }

  return (
    <div className="flex h-12 w-12 flex-shrink-0 items-center justify-center rounded-xl bg-gradient-to-br from-orange-50 to-amber-100 ring-1 ring-orange-100">
      <svg className="h-5 w-5 text-fixwise-orange" fill="none" viewBox="0 0 24 24" strokeWidth={1.8} stroke="currentColor" aria-hidden="true">
        <path strokeLinecap="round" strokeLinejoin="round" d="M3 16.5v2.25A2.25 2.25 0 005.25 21h13.5A2.25 2.25 0 0021 18.75V16.5M16.5 12L12 16.5m0 0L7.5 12m4.5 4.5V3" />
      </svg>
    </div>
  );
}

function StatusDot({ status }: { status: string }) {
  const color =
    status === 'completed'
      ? 'bg-green-500'
      : status === 'active'
        ? 'bg-blue-500'
        : 'bg-gray-400';

  return <div className={`h-2 w-2 rounded-full ${color}`} />;
}
