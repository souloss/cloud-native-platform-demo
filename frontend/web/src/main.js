import { createApp } from 'vue'
import App from './App.vue'
import './style.css'
import { configureTelemetry } from './telemetry'

const apiKey = import.meta.env.VITE_OO_RUM_CLIENT_TOKEN
const telemetryEndpoint = import.meta.env.VITE_OTEL_INGESTION_URL || window.location.origin

async function bootstrap() {
  await configureTelemetry({ apiKey, endpoint: telemetryEndpoint })
  createApp(App).mount('#app')
}

bootstrap()
