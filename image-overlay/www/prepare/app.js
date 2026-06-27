const app = document.querySelector('#app');
const token = new URLSearchParams(location.hash.slice(1)).get('token') || '';
let state = null;

async function api(action, body) {
  const response = await fetch(`/cgi-bin/router-prep?action=${encodeURIComponent(action)}`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json'
    },
    body: JSON.stringify({ token, ...(body || {}) }),
    cache: 'no-store'
  });
  const data = await response.json();
  if (!data.ok)
    throw new Error(data.error || 'Preparation action failed.');
  return data;
}

function checked(value) {
  return value ? 'checked' : '';
}

function health(name, value) {
  return `<div><strong>${name}</strong><br><span class="${value === 'up' || value === 'connected' ? 'good' : 'bad'}">${value}</span></div>`;
}

function readiness(name, value) {
  return `<div><strong>${name}</strong><br><span class="${value ? 'good' : 'bad'}">${value ? 'ready' : 'required'}</span></div>`;
}

function policyRow(id, label, note) {
  return `<div class="row"><div><label for="${id}">${label}</label><div class="subtitle">${note}</div></div><input id="${id}" type="checkbox" ${checked(state.policy[id])}></div>`;
}

function render(message = '') {
  app.innerHTML = `<div class="shell">
    <header class="top"><div><div class="eyebrow">Owner preparation</div><h1 class="title">Router developer panel</h1><div class="subtitle">Prepare, validate, and seal the device before customer handoff.</div></div><div>UI ${state.version}</div></header>
    ${message ? `<div class="notice">${message}</div>` : ''}
    <div class="grid">
      <section class="section wide"><h2>Device health</h2><div class="health">
        ${health('WAN',state.health.wan)}${health('DNS',state.health.dns)}${health('SSH',state.health.ssh)}
        ${health('Xray',state.health.xray)}${health('AdGuard',state.health.adguard)}${health('Tailscale',state.health.tailscale)}
      </div><div class="device-line">${state.device.model} · kernel ${state.device.kernel} · uptime ${Math.floor(state.device.uptimeSeconds / 60)} min</div></section>
      <section class="section wide"><h2>Handoff readiness</h2><div class="health readiness">
        ${readiness('Customer setup',state.setup.complete)}
        ${readiness('Root password',state.readiness.passwordSet)}
        ${readiness('Configuration backup',state.readiness.backupCreated)}
      </div><div class="actions"><button data-action="backup">Create verified backup</button></div>
      ${state.device.latestBackup ? `<div class="device-line">Latest: <code>${state.device.latestBackup}</code></div>` : ''}</section>
      <section class="section"><h2>Customer setup preview</h2>
        <div class="row"><div><label for="placeholder">Placeholder Wi-Fi radios</label><div class="subtitle">Show simulated 2.4 and 5 GHz radios in the customer wizard.</div></div><input id="placeholder" type="checkbox" ${checked(state.placeholderWifi)}></div>
        <div class="actions"><a class="button" href="/setup/#dev=${encodeURIComponent(token)}">Open full setup preview</a></div>
      </section>
      <section class="section"><h2>Owner tailnet</h2>
        <div class="field"><label>Control server</label><input id="ts-server" value="https://headscale.example.com"></div>
        <div class="field"><label>Preauth key</label><input id="ts-key" type="password"></div>
        <div class="field"><label>Hostname</label><input id="ts-hostname" value="openwrt-fin0"></div>
        <div class="actions"><button data-action="tailscale-up" class="primary">Enroll</button><button data-action="tailscale-logout">Logout</button></div>
      </section>
      <section class="section wide"><h2>Customer feature policy</h2>
        ${policyRow('vpn','VPN panel','Allow selecting VPN profiles, rules, and device bypasses.')}
        ${policyRow('tailscale','Tailscale panel','Hide this after owner enrollment unless the customer manages the tailnet.')}
        ${policyRow('update','Update panel','Allow customer-triggered Router UI updates.')}
        ${policyRow('packages','Package Manager','Advanced access; normally hidden for managed devices.')}
        ${policyRow('adguard','AdGuard administration','Allow LAN access to port 3000; DNS filtering remains active either way.')}
        <div class="actions"><button data-action="save-policy">Apply policy</button></div>
      </section>
      <section class="section wide"><h2>Customer handoff</h2>
        <div class="subtitle">Sealing removes placeholder radios, applies the policy, and disables this API. Reopening requires SSH: <code>router-prep unseal</code>.</div>
        <div class="actions"><button data-action="seal" class="danger">Seal for customer</button></div>
      </section>
    </div>
  </div>`;
}

function policy() {
  return {
    vpn: document.querySelector('#vpn').checked,
    tailscale: document.querySelector('#tailscale').checked,
    update: document.querySelector('#update').checked,
    packages: document.querySelector('#packages').checked,
    adguard: document.querySelector('#adguard').checked
  };
}

async function refresh(message = '') {
  state = await api('status');
  render(message);
}

app.addEventListener('change', async event => {
  if (event.target.id !== 'placeholder')
    return;
  try {
    await api('placeholder', { enabled: event.target.checked });
    await refresh('Preview radio setting updated.');
  }
  catch (error) {
    render(error.message);
  }
});

app.addEventListener('click', async event => {
  const button = event.target.closest('button');
  if (!button)
    return;
  try {
    if (button.dataset.action === 'save-policy') {
      await api('policy', { policy: policy() });
      await refresh('Customer policy applied.');
    }
    if (button.dataset.action === 'tailscale-up') {
      await api('tailscale-up', {
        server: document.querySelector('#ts-server').value,
        key: document.querySelector('#ts-key').value,
        hostname: document.querySelector('#ts-hostname').value
      });
      await refresh('Owner tailnet enrollment completed.');
    }
    if (button.dataset.action === 'tailscale-logout') {
      await api('tailscale-logout', {});
      await refresh('Tailscale logged out.');
    }
    if (button.dataset.action === 'backup') {
      const result = await api('backup', {});
      await refresh(`Verified backup created at ${result.path}.`);
    }
    if (button.dataset.action === 'seal') {
      if (!confirm('Disable the developer preparation panel and apply this customer policy?'))
        return;
      await api('seal', { policy: policy() });
      app.innerHTML = '<div class="shell"><div class="notice">Device sealed for customer handoff. This preparation panel is now disabled.</div></div>';
    }
  }
  catch (error) {
    render(error.message);
  }
});

if (!token)
  app.innerHTML = '<div class="shell"><div class="notice error">Missing preparation token. Retrieve it over SSH with <code>router-prep token</code>.</div></div>';
else
  refresh().catch(error => {
    app.innerHTML = `<div class="shell"><div class="notice error">${error.message}</div></div>`;
  });
