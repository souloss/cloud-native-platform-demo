import { createApp } from 'vue'
import HyperDX from '@hyperdx/browser'
import App from './App.vue'
import './style.css'

const apiKey = import.meta.env.VITE_HYPERDX_API_KEY
const hyperdxUrl = import.meta.env.VITE_HYPERDX_URL || `http://${window.location.hostname}:14318`
if (apiKey) {
  HyperDX.init({
    apiKey,
    service: 'k3s-gofr-web',
    tracePropagationTargets: [/\/api\//],
    consoleCapture: true,
    advancedNetworkCapture: true,
    url: hyperdxUrl,
    disableReplay: false,
    maskAllInputs: true,
    blockSelector: '[data-private]',
    otelResourceAttributes: {
      'service.version': '0.1.0',
      'deployment.environment': import.meta.env.MODE,
    },
  })
  // 虽然回放默认开启，但在演示中显式启动录制器，让行为更加清晰。
  HyperDX.resumeSessionRecorder()
}

createApp(App).mount('#app')
