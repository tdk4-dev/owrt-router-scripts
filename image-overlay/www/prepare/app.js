const app = document.querySelector('#app');
const token = new URLSearchParams(window.location.hash.slice(1)).get('token') || '';

const state = {
  loading: true,
  error: '',
  status: null
};

function escapeHtml(value) {
  return String(value ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

async function api(action, payload = {}) {
  const response = await fetch(`/cgi-bin/router-prep?action=${encodeURIComponent(action)}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ token, ...payload }),
    cache: 'no-store'
  });
  const json = await response.json();
  if (!json.ok)
    throw new Error(json.error || 'Preparation request failed.');
  return json;
}

async function refresh() {
  state.loading = true;
  state.error = '';
  render();
  try {
    await api('authorize');
    state.status = await api('status');
  }
  catch (error) {
    state.error = error.message;
  }
  state.loading = false;
  render();
}

async function setPlaceholderWifi(enabled) {
  await api('placeholder-wifi', { enabled });
  await refresh();
}

async function savePolicy(policy) {
  await api('policy', policy);
  await refresh();
}

async function seal() {
  if (!window.confirm('Seal owner preparation and remove the temporary token?'))
    return;
  await api('seal');
  state.error = 'Preparation API is sealed. Reopen with SSH or local console: router-prep unseal';
  state.status = null;
  render();
}

function policyForm(policy = {}) {
  const installMode = policy.installMode || 'owner-prepared-standard';
  const supportLevel = policy.supportLevel || 'standard';
  const registrationState = policy.registrationState || 'support-disabled';
  const checked = value => value ? 'checked' : '';
  return `
    <div class="stack">
      <div>
        <label for="install-mode">Install mode</label>
        <select id="install-mode">
          ${['owner-prepared-standard', 'owner-prepared-managed', 'self-managed-image', 'manual-ipk-install', 'dev-vm', 'unknown'].map(mode => `
            <option value="${mode}" ${mode === installMode ? 'selected' : ''}>${mode}</option>
          `).join('')}
        </select>
      </div>
      <div>
        <label for="support-level">Support level</label>
        <select id="support-level">
          ${['none', 'self-managed', 'standard', 'managed', 'priority', 'developer'].map(level => `
            <option value="${level}" ${level === supportLevel ? 'selected' : ''}>${level}</option>
          `).join('')}
        </select>
      </div>
      <div>
        <label for="registration-state">Registration/support state</label>
        <select id="registration-state">
          ${['unregistered', 'local-only', 'support-registered', 'support-enabled', 'support-disabled', 'unknown'].map(registration => `
            <option value="${registration}" ${registration === registrationState ? 'selected' : ''}>${registration}</option>
          `).join('')}
        </select>
      </div>
      ${[
        ['customerVpn', 'Customer VPN panel', policy.customerVpn],
        ['customerTailscale', 'Customer Tailscale panel', policy.customerTailscale],
        ['customerUpdates', 'Customer updates', policy.customerUpdates],
        ['customerPackages', 'Customer package controls', policy.customerPackages],
        ['customerAdguard', 'Customer AdGuard controls', policy.customerAdguard],
        ['supportAccess', 'Support access visible/enabled', policy.supportAccess]
      ].map(([id, label, value]) => `
        <label><input id="${id}" type="checkbox" ${checked(value)}> ${label}</label>
      `).join('')}
    </div>
  `;
}

function render() {
  if (!token) {
    app.innerHTML = `
      <div class="eyebrow">Owner prep</div>
      <h1>Token required</h1>
      <p class="lede">Retrieve a temporary token over trusted SSH or local console with <strong>router-prep token</strong>, then open <strong>/prepare/#token=TOKEN</strong>.</p>
    `;
    return;
  }
  if (state.loading) {
    app.innerHTML = `
      <div class="eyebrow">Owner prep</div>
      <h1>Loading preparation panel</h1>
      <p class="lede">Checking the local preparation token.</p>
    `;
    return;
  }
  if (state.error && !state.status) {
    app.innerHTML = `
      <div class="eyebrow">Owner prep</div>
      <h1>Preparation unavailable</h1>
      <p class="lede">${escapeHtml(state.error)}</p>
    `;
    return;
  }
  const status = state.status || {};
  const policy = status.policy || {};
  app.innerHTML = `
    <div class="eyebrow">Owner prep</div>
    <h1>Router preparation</h1>
    <p class="lede">Use this local-only panel before customer handoff. Support state is explicit metadata only; this panel never creates a hidden tunnel. Secrets are not displayed or stored here.</p>
    ${state.error ? `<p class="lede">${escapeHtml(state.error)}</p>` : ''}
    <section class="grid">
      <div class="panel">
        <h2>Status</h2>
        <div class="row"><span>Preparation API</span><strong class="${status.sealed ? '' : 'ok'}">${status.sealed ? 'sealed' : 'open'}</strong></div>
        <div class="row"><span>Wi-Fi preview radios</span><strong>${status.placeholderWifi ? 'enabled' : 'disabled'}</strong></div>
        <div class="actions">
          <button data-action="placeholder-on">Enable Wi-Fi preview</button>
          <button data-action="placeholder-off">Disable Wi-Fi preview</button>
          <button class="danger" data-action="seal">Seal</button>
        </div>
      </div>
      <div class="panel">
        <h2>Customer policy</h2>
        ${policyForm(policy)}
        <div class="actions">
          <button class="primary" data-action="save-policy">Save policy</button>
          <button data-action="refresh">Refresh</button>
        </div>
      </div>
    </section>
  `;
}

app.addEventListener('click', event => {
  const action = event.target?.dataset?.action;
  if (!action)
    return;
  event.preventDefault();
  if (action === 'placeholder-on')
    setPlaceholderWifi(true).catch(error => { state.error = error.message; render(); });
  if (action === 'placeholder-off')
    setPlaceholderWifi(false).catch(error => { state.error = error.message; render(); });
  if (action === 'seal')
    seal().catch(error => { state.error = error.message; render(); });
  if (action === 'refresh')
    refresh();
  if (action === 'save-policy') {
    savePolicy({
      installMode: document.querySelector('#install-mode')?.value || 'owner-prepared-standard',
      supportLevel: document.querySelector('#support-level')?.value || 'standard',
      registrationState: document.querySelector('#registration-state')?.value || 'support-disabled',
      customerVpn: document.querySelector('#customerVpn')?.checked || false,
      customerTailscale: document.querySelector('#customerTailscale')?.checked || false,
      customerUpdates: document.querySelector('#customerUpdates')?.checked || false,
      customerPackages: document.querySelector('#customerPackages')?.checked || false,
      customerAdguard: document.querySelector('#customerAdguard')?.checked || false,
      supportAccess: document.querySelector('#supportAccess')?.checked || false
    }).catch(error => { state.error = error.message; render(); });
  }
});

refresh();
