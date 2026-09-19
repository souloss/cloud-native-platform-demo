import HyperDX from '@hyperdx/browser'

const serviceName = 'k3s-gofr-web'

class NoopTelemetryProvider {
  isReady() { return false }
  trackEvent() {}
  getSessionId() { return '' }
  startReplay() {}
  stopReplay() {}
}

class HyperDXTelemetryProvider {
  constructor() {
    this.ready = true
  }

  isReady() { return this.ready }

  trackEvent(name, attributes = {}) {
    const sessionId = this.getSessionId()
    HyperDX.addAction?.(name, sessionId ? { 'ui.session.id': sessionId, ...attributes } : attributes)
  }

  getSessionId() {
    return HyperDX.getSessionId?.() || ''
  }

  startReplay() {
    HyperDX.resumeSessionRecorder?.()
  }

  stopReplay() {
    HyperDX.stopSessionRecorder?.()
  }
}

let provider = new NoopTelemetryProvider()

function trimTrailingSlash(value) {
  return value.replace(/\/+$/, '')
}

export function configureTelemetry({ apiKey, endpoint }) {
  if (!apiKey) return

  const baseURL = trimTrailingSlash(endpoint)
  HyperDX.init({
    apiKey,
    service: serviceName,
    tracePropagationTargets: [/\/api\//],
    consoleCapture: true,
    advancedNetworkCapture: true,
    url: baseURL,
    tracesUrl: `${baseURL}/v1/traces`,
    logsUrl: `${baseURL}/v1/logs`,
    disableReplay: false,
    maskAllInputs: true,
    blockSelector: '[data-private]',
    otelResourceAttributes: {
      'service.version': '0.1.0',
      'deployment.environment': import.meta.env.MODE,
    },
  })
  provider = new HyperDXTelemetryProvider()
  // 虽然回放默认开启，但在演示中显式启动录制器，让行为更加清晰。
  provider.startReplay()
}

export const telemetry = {
  isReady: () => provider.isReady(),
  trackEvent: (name, attributes = {}) => provider.trackEvent(name, attributes),
  getSessionId: () => provider.getSessionId(),
  startReplay: () => provider.startReplay(),
  stopReplay: () => provider.stopReplay(),
}
