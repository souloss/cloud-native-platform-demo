<script setup>
import { computed, onMounted, ref } from 'vue'
import { telemetry } from './telemetry'

const orders = ref([])
const catalog = ref([])
const loading = ref(true)
const error = ref('')
const feedback = ref('')
const feedbackTone = ref('success')
const busyAction = ref('')
const replaying = ref(false)
const recorderReady = ref(false)
const sessionId = ref('Not connected')
const lastAction = ref('No custom action yet')
const quantity = ref(1)
const selectedItem = ref('sku-001')
const selectedOrder = ref(null)

const currentOrder = computed(() => selectedOrder.value || orders.value[0] || null)
const ready = computed(() => !loading.value && !error.value)

function track(name, attributes = {}) {
  if (!telemetry.isReady()) return
  telemetry.trackEvent(name, attributes)
}

function notify(message, tone = 'success') {
  feedback.value = message
  feedbackTone.value = tone
}

async function request(path, options = {}) {
  const response = await fetch(path, {
    headers: { 'Content-Type': 'application/json', ...(options.headers || {}) },
    ...options,
  })
  const payload = await response.json().catch(() => ({}))
  if (!response.ok) throw new Error(payload?.error?.message || `${response.status} ${response.statusText}`)
  return payload.data
}

async function refresh(showNotice = true) {
  busyAction.value = 'refresh'
  loading.value = true
  error.value = ''
  try {
    const [nextOrders, nextCatalog] = await Promise.all([request('/api/orders'), request('/api/catalog')])
    orders.value = nextOrders
    catalog.value = nextCatalog
    if (!catalog.value.some(item => item.id === selectedItem.value)) selectedItem.value = catalog.value[0]?.id || ''
    track('catalog.loaded', { 'catalog.item_count': nextCatalog.length, 'order.item_count': nextOrders.length })
    if (showNotice) notify(`Loaded ${nextOrders.length} orders and ${nextCatalog.length} catalog items.`)
  } catch (err) {
    error.value = err.message
    track('ui.data.load_failed', { 'error.message': err.message })
    notify(`Could not load data: ${err.message}`, 'error')
  } finally {
    loading.value = false
    busyAction.value = ''
  }
}

async function createOrder() {
  if (!selectedItem.value) return notify('Choose a catalog item first.', 'error')
  busyAction.value = 'create'
  try {
    const created = await request('/api/orders', {
      method: 'POST',
      body: JSON.stringify({ itemId: selectedItem.value, quantity: Number(quantity.value) }),
    })
    orders.value = [created, ...orders.value]
    selectedOrder.value = created
    track('order.created', { 'order.id': created.id, 'order.item_id': created.itemId, 'order.quantity': created.quantity })
    notify(`Order ${created.id} created.`)
  } catch (err) {
    notify(`Could not create order: ${err.message}`, 'error')
  } finally {
    busyAction.value = ''
  }
}

async function updateCurrentOrder() {
  if (!currentOrder.value) return notify('Select an order to update.', 'error')
  busyAction.value = 'update'
  try {
    const updated = await request(`/api/orders/${currentOrder.value.id}`, {
      method: 'PATCH',
      body: JSON.stringify({ itemId: currentOrder.value.itemId, quantity: currentOrder.value.quantity, state: currentOrder.value.state }),
    })
    orders.value = orders.value.map(order => order.id === updated.id ? updated : order)
    selectedOrder.value = updated
    track('order.updated', { 'order.id': updated.id, 'order.state': updated.state })
    notify(`Order ${updated.id} saved.`)
  } catch (err) {
    notify(`Could not save order: ${err.message}`, 'error')
  } finally {
    busyAction.value = ''
  }
}

async function deleteCurrentOrder() {
  if (!currentOrder.value) return notify('Select an order to delete.', 'error')
  if (!window.confirm(`Delete order ${currentOrder.value.id}?`)) return
  busyAction.value = 'delete'
  try {
    const id = currentOrder.value.id
    await request(`/api/orders/${id}`, { method: 'DELETE' })
    orders.value = orders.value.filter(order => order.id !== id)
    selectedOrder.value = orders.value[0] || null
    track('order.deleted', { 'order.id': id })
    notify(`Order ${id} deleted.`)
  } catch (err) {
    notify(`Could not delete order: ${err.message}`, 'error')
  } finally {
    busyAction.value = ''
  }
}

function toggleReplay() {
  if (!recorderReady.value) return notify('HyperDX is not connected for this session.', 'error')
  if (replaying.value) {
    telemetry.stopReplay()
    replaying.value = false
    lastAction.value = 'Recording paused'
    track('ui.session.replay.paused')
    notify('Session replay paused.')
  } else {
    telemetry.startReplay()
    replaying.value = true
    lastAction.value = 'Recording resumed'
    track('ui.session.replay.resumed')
    notify('Session replay is recording.')
  }
}

function recordDemoAction() {
  if (!recorderReady.value) return notify('HyperDX is not connected for this session.', 'error')
  const recordedAt = new Date()
  track('ui.demo.action', { 'ui.action.source': 'vue-crud-button', 'ui.action.recorded_at': recordedAt.toISOString() })
  lastAction.value = `Demo action recorded at ${recordedAt.toLocaleTimeString()}`
  notify('Demo action recorded in the current session.')
}

async function copySessionId() {
  try {
    await navigator.clipboard.writeText(sessionId.value)
    notify('Session ID copied.')
  } catch {
    notify('Clipboard access is unavailable.', 'error')
  }
}

function formatDate(value) {
  return new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(value))
}

onMounted(async () => {
  sessionId.value = telemetry.getSessionId() || 'Not connected'
  recorderReady.value = sessionId.value !== 'Not connected'
  replaying.value = recorderReady.value
  await refresh(false)
})
</script>

<template>
  <main>
    <header class="hero">
      <div>
        <span class="eyebrow">K3S / GATEWAY API / HYPERDX V2</span>
        <h1>Order desk</h1>
        <p class="lede">A small observable workflow backed by GoFr, PostgreSQL, MySQL and Redis.</p>
      </div>
      <div class="hero-route" aria-label="Request path">
        <span>Browser</span><b>→</b><span>Gateway</span><b>→</b><span>Orders</span><b>→</b><span>Data</span>
      </div>
    </header>

    <section class="replay-bar" aria-label="Session replay">
      <div class="replay-state">
        <span class="status-dot" :class="{ active: replaying }" aria-hidden="true"></span>
        <div><strong>Session replay {{ replaying ? 'recording' : 'paused' }}</strong><span class="muted">{{ lastAction }}</span></div>
      </div>
      <div class="toolbar">
        <button :class="replaying ? 'secondary' : 'primary'" :disabled="busyAction !== ''" @click="toggleReplay">{{ replaying ? 'Pause recording' : 'Resume recording' }}</button>
        <button class="secondary" :disabled="busyAction !== ''" @click="recordDemoAction">Mark demo action</button>
        <button class="secondary" :disabled="busyAction !== ''" @click="refresh()">Refresh</button>
      </div>
      <div class="session-row"><span>Session <code>{{ sessionId }}</code></span><button class="text-button" :disabled="sessionId === 'Not connected'" @click="copySessionId">Copy ID</button></div>
    </section>

    <div class="notice" :class="feedbackTone" aria-live="polite">{{ feedback || (ready ? 'Ready' : 'Loading…') }}</div>

    <section class="metrics" aria-label="Workspace status">
      <div><span>Orders</span><strong>{{ orders.length }}</strong></div><div><span>Catalog</span><strong>{{ catalog.length }}</strong></div><div><span>Gateway</span><strong class="healthy">Ready</strong></div><div><span>Recorder</span><strong :class="replaying ? 'healthy' : 'muted'">{{ replaying ? 'On' : 'Paused' }}</strong></div>
    </section>

    <section class="panel create-panel">
      <div class="panel-heading"><div><small>CREATE</small><h2>New order</h2></div><button class="primary" :disabled="busyAction !== '' || !catalog.length" @click="createOrder">{{ busyAction === 'create' ? 'Creating…' : 'Create order' }}</button></div>
      <div class="form-row"><label>Catalog item<select v-model="selectedItem" name="catalog-item" :disabled="busyAction !== ''"><option v-for="item in catalog" :key="item.id" :value="item.id">{{ item.id }} · {{ item.name }}</option></select></label><label>Quantity<input v-model.number="quantity" name="quantity" type="number" min="1" inputmode="numeric" :disabled="busyAction !== ''" /></label></div>
    </section>

    <section class="panel">
      <div class="panel-heading"><div><small>READ / UPDATE / DELETE</small><h2>Orders</h2></div><div class="actions"><button class="secondary" :disabled="busyAction !== '' || !currentOrder" @click="updateCurrentOrder">{{ busyAction === 'update' ? 'Saving…' : 'Save selected' }}</button><button class="danger" :disabled="busyAction !== '' || !currentOrder" @click="deleteCurrentOrder">{{ busyAction === 'delete' ? 'Deleting…' : 'Delete selected' }}</button></div></div>
      <div v-if="orders.length" class="table-wrap"><table><thead><tr><th scope="col">Order</th><th scope="col">Item</th><th scope="col">Qty</th><th scope="col">State</th><th scope="col">Updated</th></tr></thead><tbody><tr v-for="order in orders" :key="order.id" :class="{ selected: currentOrder?.id === order.id }" @click="selectedOrder = order"><td><button class="row-button" @click.stop="selectedOrder = order">{{ order.id }}</button></td><td>{{ order.itemId }}</td><td><input v-model.number="order.quantity" :aria-label="`Quantity for ${order.id}`" type="number" min="1" @click.stop /></td><td><select v-model="order.state" :aria-label="`State for ${order.id}`" @click.stop><option>created</option><option>confirmed</option><option>ready</option><option>cancelled</option></select></td><td class="date">{{ formatDate(order.updatedAt) }}</td></tr></tbody></table></div><div v-else class="empty">No orders yet.</div>
    </section>

    <section class="panel"><div class="panel-heading"><div><small>MYSQL + REDIS</small><h2>Catalog</h2></div><span class="muted">{{ catalog.length }} items</span></div><div v-if="catalog.length" class="catalog-grid"><article v-for="item in catalog" :key="item.id"><div class="catalog-id">{{ item.id }}</div><strong>{{ item.name }}</strong><p>{{ item.description }}</p></article></div><div v-else class="empty">Catalog is empty.</div></section>
  </main>
</template>
