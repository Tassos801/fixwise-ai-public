export interface SessionListItem {
  id: string;
  status: string;
  stepCount: number;
  startedAt: string;
  endedAt: string | null;
  reportUrl: string | null;
  summary?: string | null;
  taskSummary?: string | null;
  overview?: string | null;
  nextAction?: string | null;
  lastNextAction?: string | null;
  followUpPrompts?: string[] | null;
  confidence?: string | null;
  thumbnailUrl?: string | null;
  frameThumbnailUrl?: string | null;
  previewThumbnailUrl?: string | null;
  latestFrameThumbnail?: string | null;
  thumbnail?: string | null;
  frameThumbnail?: string | null;
  thumbnailDataUrl?: string | null;
}

export interface SessionStepItem {
  stepNumber: number;
  text: string;
  safetyWarning: string | null;
  hasFrame: boolean;
  createdAt: string;
  summary?: string | null;
  nextAction?: string | null;
  followUpPrompts?: string[] | null;
  confidence?: string | null;
  thumbnailUrl?: string | null;
  frameThumbnailUrl?: string | null;
  thumbnail?: string | null;
  frameThumbnail?: string | null;
  previewThumbnailUrl?: string | null;
  thumbnailDataUrl?: string | null;
}

export interface SessionDetailItem extends SessionListItem {
  steps: SessionStepItem[];
}

function firstNonEmpty(values: Array<string | null | undefined>): string | null {
  for (const value of values) {
    if (typeof value === 'string') {
      const trimmed = value.trim();
      if (trimmed.length > 0) {
        return trimmed;
      }
    }
  }
  return null;
}

export function resolveSessionSummary(session: Pick<SessionListItem, 'summary' | 'taskSummary' | 'overview'>): string | null {
  return firstNonEmpty([session.summary, session.taskSummary, session.overview]);
}

export function resolveSessionNextAction(
  session: Pick<SessionListItem, 'nextAction' | 'lastNextAction'>,
): string | null {
  return firstNonEmpty([session.nextAction, session.lastNextAction]);
}

export function resolveSessionConfidence(session: Pick<SessionListItem, 'confidence'>): string | null {
  return firstNonEmpty([session.confidence]);
}

export function normalizeThumbnailSource(source?: string | null): string | null {
  if (!source) {
    return null;
  }

  const trimmed = source.trim();
  if (!trimmed) {
    return null;
  }

  if (trimmed.startsWith('data:') || trimmed.startsWith('http://') || trimmed.startsWith('https://') || trimmed.startsWith('/')) {
    return trimmed;
  }

  if (trimmed.startsWith('base64,')) {
    return `data:image/jpeg;base64,${trimmed.slice('base64,'.length)}`;
  }

  return `data:image/jpeg;base64,${trimmed}`;
}

export function resolveSessionThumbnail(session: Pick<SessionListItem,
  'thumbnailUrl' | 'frameThumbnailUrl' | 'previewThumbnailUrl' | 'latestFrameThumbnail' | 'thumbnail' | 'frameThumbnail' | 'thumbnailDataUrl'
>): string | null {
  return normalizeThumbnailSource(
    session.thumbnailUrl
      ?? session.frameThumbnailUrl
      ?? session.previewThumbnailUrl
      ?? session.latestFrameThumbnail
      ?? session.thumbnail
      ?? session.frameThumbnail
      ?? session.thumbnailDataUrl,
  );
}

export function resolveStepThumbnail(step: Pick<SessionStepItem,
  'thumbnailUrl' | 'frameThumbnailUrl' | 'thumbnail' | 'frameThumbnail' | 'previewThumbnailUrl' | 'thumbnailDataUrl'
>): string | null {
  return normalizeThumbnailSource(
    step.thumbnailUrl
      ?? step.frameThumbnailUrl
      ?? step.thumbnail
      ?? step.frameThumbnail
      ?? step.previewThumbnailUrl
      ?? step.thumbnailDataUrl,
  );
}

export function formatConfidenceLabel(confidence?: string | null): string | null {
  const normalized = firstNonEmpty([confidence]);
  if (!normalized) {
    return null;
  }

  return normalized.charAt(0).toUpperCase() + normalized.slice(1);
}
