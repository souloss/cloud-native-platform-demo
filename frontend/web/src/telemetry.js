const serviceName = 'k3s-gofr-web'

class NoopTelemetryProvider {
  isReady() { return false }
  trackEvent() {}
  getSessionId() { return '' }
  startReplay() {}
  stopReplay() {}
}

class OpenObserveTelemetryProvider {
  constructor(rum) {
    this.rum = rum
    this.ready = true
  }

  isReady() { return this.ready }

  trackEvent(name, attributes = {}) {
    const sessionId = this.getSessionId()
    this.rum.addAction?.(name, sessionId ? { 'ui.session.id': sessionId, ...attributes } : attributes)
  }

  getSessionId() {
    return this.rum.getInternalContext?.()?.sessionId || ''
  }

  startReplay() {
    this.rum.startSessionReplayRecording?.({ force: true })
  }

  stopReplay() {
    this.rum.stopSessionReplayRecording?.()
  }
}

let provider = new NoopTelemetryProvider()

export async function configureTelemetry({ apiKey, endpoint }) {
  if (import.meta.env.VITE_OBSERVABILITY_BACKEND !== 'openobserve' || !apiKey) return

  const applicationId = import.meta.env.VITE_OO_RUM_APPLICATION_ID
  const site = import.meta.env.VITE_OO_RUM_SITE || endpoint
  if (!applicationId || !site) return

  const { openobserveRum } = await import('@openobserve/browser-rum')
  openobserveRum.init({
    applicationId,
    clientToken: apiKey,
    site,
    service: serviceName,
    env: import.meta.env.MODE,
    version: import.meta.env.VITE_APP_VERSION || 'dev',
    sessionSampleRate: Number(import.meta.env.VITE_OO_RUM_SESSION_SAMPLE_RATE || 20),
    sessionReplaySampleRate: Number(import.meta.env.VITE_OO_RUM_REPLAY_SAMPLE_RATE || 5),
    trackResources: true,
    trackLongTasks: true,
    trackUserInteractions: true,
    defaultPrivacyLevel: 'mask-user-input',
    allowedTracingUrls: [/\/api\//],
    startSessionReplayRecordingManually: true,
  })
  provider = new OpenObserveTelemetryProvider(openobserveRum)
}

export const telemetry = {
  isReady: () => provider.isReady(),
  trackEvent: (name, attributes = {}) => provider.trackEvent(name, attributes),
  getSessionId: () => provider.getSessionId(),
  startReplay: () => provider.startReplay(),
  stopReplay: () => provider.stopReplay(),
}
