import { useAuth } from '../services/auth';

interface Tier {
  name: string;
  price: string;
  period: string;
  tier: string;
  highlight?: boolean;
  features: { label: string; included: boolean }[];
}

const TIERS: Tier[] = [
  {
    name: 'Free',
    price: '$0',
    period: 'forever',
    tier: 'free',
    features: [
      { label: '3 sessions per month', included: true },
      { label: '5 minutes per session', included: true },
      { label: 'Requires your own API key (BYOK)', included: true },
      { label: 'Fix Reports', included: false },
      { label: 'Priority support', included: false },
    ],
  },
  {
    name: 'Pro',
    price: '$19.99',
    period: '/month',
    tier: 'pro',
    highlight: true,
    features: [
      { label: 'Unlimited sessions', included: true },
      { label: '30 minutes per session', included: true },
      { label: 'Platform-managed AI key', included: true },
      { label: 'Fix Reports included', included: true },
      { label: 'Priority support', included: false },
    ],
  },
  {
    name: 'Enterprise',
    price: 'Custom',
    period: '',
    tier: 'enterprise',
    features: [
      { label: 'Unlimited sessions', included: true },
      { label: 'Unlimited duration', included: true },
      { label: 'Dedicated AI capacity', included: true },
      { label: 'Fix Reports included', included: true },
      { label: 'Priority support + custom safety rules', included: true },
    ],
  },
];

export function SubscriptionPage() {
  const { user } = useAuth();
  const currentTier = user?.tier ?? 'free';

  return (
    <div>
      <div className="mb-8">
        <h1 className="text-2xl font-bold text-gray-900">Subscription</h1>
        <p className="mt-1 text-sm text-gray-500">
          Choose the plan that fits your needs.
        </p>
      </div>

      {/* Tier Cards */}
      <div className="grid grid-cols-1 gap-6 md:grid-cols-3">
        {TIERS.map((tier) => {
          const isCurrent = tier.tier === currentTier;
          return (
            <div
              key={tier.tier}
              className={`relative rounded-2xl bg-white p-6 shadow-sm ring-1 ${
                tier.highlight
                  ? 'ring-fixwise-orange shadow-md'
                  : 'ring-gray-200'
              }`}
            >
              {tier.highlight && (
                <span className="absolute -top-3 left-1/2 -translate-x-1/2 rounded-full bg-fixwise-orange px-3 py-0.5 text-xs font-semibold text-white">
                  Most Popular
                </span>
              )}

              <h3 className="text-lg font-semibold text-gray-900">{tier.name}</h3>
              <div className="mt-2 flex items-baseline gap-1">
                <span className="text-3xl font-bold text-fixwise-dark">{tier.price}</span>
                {tier.period && (
                  <span className="text-sm text-gray-500">{tier.period}</span>
                )}
              </div>

              <ul className="mt-6 space-y-3">
                {tier.features.map((f) => (
                  <li key={f.label} className="flex items-start gap-2 text-sm">
                    {f.included ? (
                      <CheckIcon className="mt-0.5 h-4 w-4 flex-shrink-0 text-fixwise-teal" />
                    ) : (
                      <XIcon className="mt-0.5 h-4 w-4 flex-shrink-0 text-gray-300" />
                    )}
                    <span className={f.included ? 'text-gray-700' : 'text-gray-400'}>
                      {f.label}
                    </span>
                  </li>
                ))}
              </ul>

              <div className="mt-6">
                {isCurrent ? (
                  <span className="block w-full rounded-lg border border-fixwise-orange bg-fixwise-orange/5 py-2 text-center text-sm font-semibold text-fixwise-orange">
                    Current Plan
                  </span>
                ) : tier.tier === 'enterprise' ? (
                  <button className="block w-full rounded-lg border border-gray-300 py-2 text-center text-sm font-semibold text-gray-700 hover:bg-gray-50">
                    Contact Sales
                  </button>
                ) : (
                  <button
                    className={`block w-full rounded-lg py-2 text-center text-sm font-semibold text-white shadow-sm ${
                      tier.highlight
                        ? 'bg-fixwise-orange hover:bg-orange-600'
                        : 'bg-gray-800 hover:bg-gray-700'
                    }`}
                  >
                    Upgrade to {tier.name}
                  </button>
                )}
              </div>
            </div>
          );
        })}
      </div>

      {/* Usage Section */}
      <div className="mt-10 rounded-xl bg-white p-6 shadow-sm ring-1 ring-gray-200">
        <h2 className="text-lg font-semibold text-gray-900">Current Usage</h2>
        <div className="mt-4 grid grid-cols-1 gap-6 sm:grid-cols-2">
          <div>
            <p className="text-sm text-gray-500">Sessions this month</p>
            <div className="mt-2 flex items-center gap-3">
              <div className="h-2 flex-1 rounded-full bg-gray-100">
                <div
                  className="h-2 rounded-full bg-fixwise-orange transition-all"
                  style={{
                    width: `${currentTier === 'free' ? Math.min(100, (0 / 3) * 100) : 0}%`,
                  }}
                />
              </div>
              <span className="text-sm font-medium text-gray-700">
                {currentTier === 'free' ? '0 / 3' : 'Unlimited'}
              </span>
            </div>
          </div>
          <div>
            <p className="text-sm text-gray-500">Max session duration</p>
            <p className="mt-2 text-sm font-medium text-gray-700">
              {currentTier === 'free'
                ? '5 minutes'
                : currentTier === 'pro'
                  ? '30 minutes'
                  : 'Unlimited'}
            </p>
          </div>
        </div>
      </div>

      {/* Billing History */}
      <div className="mt-6 rounded-xl bg-white p-6 shadow-sm ring-1 ring-gray-200">
        <h2 className="text-lg font-semibold text-gray-900">Billing History</h2>
        <div className="mt-4 py-8 text-center">
          <p className="text-sm text-gray-400">No billing history yet.</p>
          <p className="mt-1 text-xs text-gray-300">Stripe integration coming soon.</p>
        </div>
      </div>
    </div>
  );
}

function CheckIcon({ className }: { className?: string }) {
  return (
    <svg className={className} fill="none" viewBox="0 0 24 24" strokeWidth={2.5} stroke="currentColor">
      <path strokeLinecap="round" strokeLinejoin="round" d="M4.5 12.75l6 6 9-13.5" />
    </svg>
  );
}

function XIcon({ className }: { className?: string }) {
  return (
    <svg className={className} fill="none" viewBox="0 0 24 24" strokeWidth={2.5} stroke="currentColor">
      <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
    </svg>
  );
}
