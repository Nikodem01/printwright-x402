import * as Sentry from "@sentry/node";

export function sentryOptions(environment = process.env) {
  if (!environment.SENTRY_DSN) return null;

  const configuredRate = Number(environment.SENTRY_TRACES_SAMPLE_RATE || 0);
  const tracesSampleRate = Number.isFinite(configuredRate)
    ? Math.min(1, Math.max(0, configuredRate))
    : 0;
  return {
    dsn: environment.SENTRY_DSN,
    environment: environment.SENTRY_ENVIRONMENT || environment.NODE_ENV || "production",
    release: environment.SENTRY_RELEASE || undefined,
    sendDefaultPii: false,
    tracesSampleRate,
  };
}

const options = sentryOptions();
if (options) Sentry.init(options);
