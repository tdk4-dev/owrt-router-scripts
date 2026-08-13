const steps = [
  {
    id: 'account',
    label: 'Account',
    eyebrow: 'First boot',
    title: 'Create the router login',
    lede: 'Set the SSH credentials that will protect the router after the assistant finishes.'
  },
  {
    id: 'vpn',
    label: 'VPN',
    eyebrow: 'Connectivity',
    title: 'Choose the VPN startup state',
    lede: 'The image can boot with transparent Xray routing enabled or leave it disabled until later.'
  },
  {
    id: 'adguard',
    label: 'AdGuard',
    eyebrow: 'DNS filtering',
    title: 'Select DNS blocklists',
    lede: 'Pick the AdGuard hostlists that should be written into the first AdGuardHome config.'
  },
  {
    id: 'tailscale',
    label: 'Tailscale',
    eyebrow: 'Remote access',
    title: 'Add tailnet access',
    lede: 'Enable Tailscale or Headscale during first boot when you already have a reusable preauth key.'
  },
  {
    id: 'review',
    label: 'Review',
    eyebrow: 'Apply',
    title: 'Review first-boot changes',
    lede: 'The router validates each choice before applying it. Secrets are never returned in setup responses.'
  }
];

const state = {
  ready: false,
  step: 0,
  errors: [],
  applying: false,
  applied: null,
  adguardAvailable: false,
  filterQuery: '',
  router: {
    hostname: 'openwrt-fin0',
    lanIp: '10.77.0.1',
    firmware: 'OpenWrt 24.10.5 x86/64'
  },
  filters: [],
  form: {
    account: {
      login: 'root',
      password: '',
      passwordConfirm: '',
      authorizedKeys: ''
    },
    vpn: {
      enabled: true,
      vlessUrl: ''
    },
    adguard: {
      enabled: false,
      selectedFilterIds: []
    },
    tailscale: {
      enabled: false,
      loginServer: 'https://headscale.example.com',
      authKey: ''
    }
  }
};

const app = document.querySelector('#app');
const routerApiMode = window.location.pathname.startsWith('/setup/');

function apiUrl(action) {
  if (routerApiMode)
    return `/cgi-bin/firstboot-setup?action=${encodeURIComponent(action)}`;
  return `/api/${encodeURIComponent(action)}`;
}

function escapeHtml(value) {
  return String(value ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function attr(value) {
  return escapeHtml(value);
}

function selectedFilters() {
  const selected = new Set(state.form.adguard.selectedFilterIds);
  return state.filters.filter(filter => selected.has(filter.id));
}

function writeNested(path, value) {
  const parts = path.split('.');
  let target = state.form;
  for (let i = 0; i < parts.length - 1; i += 1)
    target = target[parts[i]];
  target[parts[parts.length - 1]] = value;
}

function clearErrorsInPlace() {
  state.errors = [];
  document.querySelector('.errors')?.remove();
}

function updateNested(path, value) {
  writeNested(path, value);
  clearErrorsInPlace();
}

function setNested(path, value) {
  writeNested(path, value);
  state.errors = [];
  render();
}

function validateStep(index = state.step) {
  const errors = [];
  const form = state.form;
  const id = steps[index].id;

  if (id === 'account') {
    if (!form.account.login.trim())
      errors.push('SSH login is required.');
    if (form.account.login.trim() !== 'root')
      errors.push('This OpenWrt image supports root SSH login only.');
    if (form.account.password.length < 8)
      errors.push('SSH password must be at least 8 characters.');
    if (form.account.password !== form.account.passwordConfirm)
      errors.push('Password confirmation does not match.');
  }

  if (id === 'vpn' && form.vpn.enabled) {
    const vpnUrl = form.vpn.vlessUrl.trim();
    if (!vpnUrl.startsWith('vless://') && !vpnUrl.startsWith('https://'))
      errors.push('Paste a valid VLESS link or HTTPS subscription link, or disable VPN for first boot.');
  }

  if (id === 'adguard' && state.adguardAvailable && form.adguard.enabled && selectedFilters().length === 0)
    errors.push('Select at least one AdGuard blocklist.');

  if (id === 'tailscale' && form.tailscale.enabled) {
    if (!form.tailscale.loginServer.trim().startsWith('https://'))
      errors.push('Tailscale or Headscale URL must use HTTPS.');
    if (!form.tailscale.authKey.trim())
      errors.push('Tailscale preauth key is required.');
  }

  return errors;
}

function canJumpTo(index) {
  if (index <= state.step)
    return true;

  for (let i = 0; i < index; i += 1) {
    if (validateStep(i).length)
      return false;
  }
  return true;
}

function goTo(index) {
  if (!canJumpTo(index))
    return;
  state.step = index;
  state.errors = [];
  render();
}

function nextStep() {
  const errors = validateStep();
  if (errors.length) {
    state.errors = errors;
    render();
    return;
  }

  if (state.step < steps.length - 1) {
    state.step += 1;
    state.errors = [];
    render();
  }
}

function previousStep() {
  if (state.step > 0) {
    state.step -= 1;
    state.errors = [];
    render();
  }
}

function toggleFilter(id, checked) {
  const selected = new Set(state.form.adguard.selectedFilterIds);
  if (checked)
    selected.add(id);
  else
    selected.delete(id);
  state.form.adguard.selectedFilterIds = Array.from(selected);
  clearErrorsInPlace();
  refreshAdguardFilterList();
}

function useRouterDefaults() {
  state.form.adguard.selectedFilterIds = state.filters
    .filter(filter => filter.enabled)
    .map(filter => filter.id);
  state.filterQuery = '';
  state.errors = [];
  const search = document.querySelector('#filter-search');
  if (search)
    search.value = '';
  refreshAdguardFilterList();
}

function selectVisibleFilters() {
  const selected = new Set(state.form.adguard.selectedFilterIds);
  filteredFilters().forEach(filter => selected.add(filter.id));
  state.form.adguard.selectedFilterIds = Array.from(selected);
  refreshAdguardFilterList();
}

function filteredFilters() {
  const query = state.filterQuery.trim().toLowerCase();
  if (!query)
    return state.filters;
  return state.filters.filter(filter => {
    return filter.name.toLowerCase().includes(query) ||
      filter.url.toLowerCase().includes(query) ||
      filter.category.toLowerCase().includes(query);
  });
}

function groupFilters(filters) {
  return filters.reduce((groups, filter) => {
    const key = filter.category || 'Other';
    if (!groups[key])
      groups[key] = [];
    groups[key].push(filter);
    return groups;
  }, {});
}

function renderFilterRows() {
  const selected = new Set(state.form.adguard.selectedFilterIds);
  const filters = filteredFilters();
  const groups = groupFilters(filters);

  return Object.keys(groups).map(category => {
    const body = groups[category].map(filter => `
      <label class="filter-row ${selected.has(filter.id) ? 'filter-selected' : ''}">
        <input
          type="checkbox"
          data-filter-id="${attr(filter.id)}"
          ${selected.has(filter.id) ? 'checked' : ''}>
        <span>
          <span class="filter-name">${escapeHtml(filter.name)}</span>
          <span class="filter-url">${escapeHtml(filter.url)}</span>
        </span>
        ${filter.enabled ? '<span class="badge good">Router default</span>' : '<span class="badge">Available</span>'}
      </label>
    `).join('');
    return `<div class="filter-group">${escapeHtml(category)}</div>${body}`;
  }).join('') || '<div class="hint">No filters match the search.</div>';
}

function refreshAdguardFilterList() {
  const summary = document.querySelector('#filter-selection-summary');
  const list = document.querySelector('#filter-list');

  if (summary)
    summary.textContent = `${state.form.adguard.selectedFilterIds.length} selected from ${state.filters.length} AdGuard hostlists.`;
  if (list)
    list.innerHTML = renderFilterRows();
}

function inputField({ id, label, type = 'text', value, path, hint = '', autocomplete = '' }) {
  return `
    <div class="field">
      <label for="${id}">${escapeHtml(label)}</label>
      <input
        id="${id}"
        type="${type}"
        value="${attr(value)}"
        data-path="${attr(path)}"
        autocomplete="${attr(autocomplete)}">
      ${hint ? `<div class="hint">${escapeHtml(hint)}</div>` : ''}
    </div>
  `;
}

function textareaField({ id, label, value, path, hint = '' }) {
  return `
    <div class="field full">
      <label for="${id}">${escapeHtml(label)}</label>
      <textarea id="${id}" data-path="${attr(path)}" spellcheck="false">${escapeHtml(value)}</textarea>
      ${hint ? `<div class="hint">${escapeHtml(hint)}</div>` : ''}
    </div>
  `;
}

function renderAccount() {
  const account = state.form.account;
  return `
    <div class="form-grid">
      ${inputField({
        id: 'account-login',
        label: 'SSH login',
        value: account.login,
        path: 'account.login',
        autocomplete: 'username',
        hint: 'OpenWrt uses root for SSH administration in this image.'
      })}
      ${inputField({
        id: 'account-password',
        label: 'SSH password',
        type: 'password',
        value: account.password,
        path: 'account.password',
        autocomplete: 'new-password'
      })}
      ${inputField({
        id: 'account-password-confirm',
        label: 'Confirm password',
        type: 'password',
        value: account.passwordConfirm,
        path: 'account.passwordConfirm',
        autocomplete: 'new-password'
      })}
      <div class="field">
        <label>Router address</label>
        <div class="badge good">http://${escapeHtml(state.router.lanIp)}</div>
        <div class="hint">The image is staged to boot its LAN on this address.</div>
      </div>
      ${textareaField({
        id: 'authorized-keys',
        label: 'Authorized SSH keys',
        value: account.authorizedKeys,
        path: 'account.authorizedKeys',
        hint: 'Optional. One public key per line.'
      })}
    </div>
  `;
}

function renderVpn() {
  const vpn = state.form.vpn;
  return `
    <div class="choice-set">
      <label class="choice-row">
        <input type="radio" name="vpn-enabled" value="1" ${vpn.enabled ? 'checked' : ''}>
        <span>
          <span class="choice-title">Enable VPN on first boot</span>
          <span class="choice-detail">Xray and transparent routing start after the VLESS config passes validation.</span>
        </span>
      </label>
      <label class="choice-row">
        <input type="radio" name="vpn-enabled" value="0" ${!vpn.enabled ? 'checked' : ''}>
        <span>
          <span class="choice-title">Leave VPN disabled</span>
          <span class="choice-detail">LuCI stays available and the VPN panel can be configured later.</span>
        </span>
      </label>
    </div>
    <div class="form-grid ${vpn.enabled ? '' : 'hidden'}">
      <div class="field full">
        <label for="vless-url">VLESS or subscription link</label>
        <input
          id="vless-url"
          type="text"
          value="${attr(vpn.vlessUrl)}"
          data-path="vpn.vlessUrl"
          placeholder="vless://... or https://provider.example/sub/...">
        <div class="hint">The final router helper will import this into the VPN panel profile store.</div>
      </div>
    </div>
  `;
}

function renderAdguard() {
  if (!state.adguardAvailable) {
    return `
      <div class="notice">
        <strong>AdGuardHome is not installed on this router.</strong>
        <p>Setup will leave the existing DNS configuration unchanged and continue safely.</p>
      </div>
    `;
  }
  return `
    <div class="choice-set">
      <label class="choice-row">
        <input type="radio" name="adguard-enabled" value="0" ${!state.form.adguard.enabled ? 'checked' : ''}>
        <span><span class="choice-title">Skip AdGuardHome</span><span class="choice-detail">Leave the existing DNS state unchanged.</span></span>
      </label>
      <label class="choice-row">
        <input type="radio" name="adguard-enabled" value="1" ${state.form.adguard.enabled ? 'checked' : ''}>
        <span><span class="choice-title">Configure AdGuardHome</span><span class="choice-detail">Initialize the installed service with the selected filters.</span></span>
      </label>
    </div>
    <div class="${state.form.adguard.enabled ? '' : 'hidden'}">
    <div class="filter-tools">
      <input
        id="filter-search"
        type="search"
        value="${attr(state.filterQuery)}"
        placeholder="Search blocklists"
        aria-label="Search blocklists">
      <button class="secondary" data-action="router-defaults">Router defaults</button>
      <button class="secondary" data-action="select-visible">Select visible</button>
    </div>
    <div class="hint" id="filter-selection-summary">${state.form.adguard.selectedFilterIds.length} selected from ${state.filters.length} AdGuard hostlists.</div>
    <div class="filter-list" id="filter-list">
      ${renderFilterRows()}
    </div>
    </div>
  `;
}

function renderTailscale() {
  const tailscale = state.form.tailscale;
  return `
    <div class="choice-set">
      <label class="choice-row">
        <input type="radio" name="tailscale-enabled" value="0" ${!tailscale.enabled ? 'checked' : ''}>
        <span>
          <span class="choice-title">Skip Tailscale setup</span>
          <span class="choice-detail">The daemon can still be installed and configured manually from SSH later.</span>
        </span>
      </label>
      <label class="choice-row">
        <input type="radio" name="tailscale-enabled" value="1" ${tailscale.enabled ? 'checked' : ''}>
        <span>
          <span class="choice-title">Connect to Tailscale or Headscale</span>
          <span class="choice-detail">The router advertises the LAN route and exit node during first boot.</span>
        </span>
      </label>
    </div>
    <div class="form-grid ${tailscale.enabled ? '' : 'hidden'}">
      ${inputField({
        id: 'tailscale-url',
        label: 'Login server URL',
        value: tailscale.loginServer,
        path: 'tailscale.loginServer',
        hint: 'Use the Headscale URL or the official Tailscale control URL.',
        autocomplete: 'url'
      })}
      ${inputField({
        id: 'tailscale-key',
        label: 'Preauth key',
        type: 'password',
        value: tailscale.authKey,
        path: 'tailscale.authKey',
        autocomplete: 'off'
      })}
    </div>
  `;
}

function renderReview() {
  const selected = selectedFilters();
  const tailscale = state.form.tailscale;
  const vpn = state.form.vpn;

  if (state.applied)
    return renderApplied();

  return `
    <div class="review">
      ${reviewRow('Router', `${state.router.hostname} on ${state.router.lanIp}`)}
      ${reviewRow('SSH login', state.form.account.login)}
      ${reviewRow('SSH password', state.form.account.password ? 'Will be set' : 'Missing')}
      ${reviewRow('VPN', vpn.enabled ? (vpn.vlessUrl.trim().startsWith('https://') ? 'Enabled with subscription profile' : 'Enabled with VLESS profile') : 'Disabled on first boot')}
      ${reviewRow('AdGuard', state.adguardAvailable && state.form.adguard.enabled
        ? selected.map(filter => filter.name).join(', ') : 'Skipped')}
      ${reviewRow('Tailscale', tailscale.enabled ? `Enabled with ${tailscale.loginServer}` : 'Skipped')}
      ${reviewRow('Secrets', 'Passwords, VLESS links, and preauth keys are not returned after submission.')}
    </div>
  `;
}

function reviewRow(label, value) {
  return `
    <div class="review-row">
      <div class="review-label">${escapeHtml(label)}</div>
      <div class="review-value">${escapeHtml(value || '-')}</div>
    </div>
  `;
}

function renderApplied() {
  const apply = state.applied;
  const preview = apply.preview || {};
  const router = preview.router || {};
  const adguardEnabled = !!preview.adguard?.enabled && !!preview.adguard?.available;
  return `
    <div class="apply-log">
      ${apply.phases.map(phase => `
        <div class="phase">
          <span class="phase-dot"></span>
          <span>${escapeHtml(phase)}</span>
        </div>
      `).join('')}
    </div>
    <div class="review">
      ${reviewRow('Mock apply id', apply.id)}
      ${reviewRow('Applied at', apply.appliedAt)}
      ${reviewRow('VPN panel', router.vpnUrl || '-')}
      ${reviewRow('AdGuard', adguardEnabled ? 'Configured' : 'Skipped')}
    </div>
    <div class="link-row">
      <a href="${attr(router.luciUrl || '#')}" target="_blank" rel="noreferrer">LuCI</a>
      <a href="${attr(router.vpnUrl || '#')}" target="_blank" rel="noreferrer">VPN panel</a>
      ${adguardEnabled ? `<a href="${attr(router.adguardUrl || `http://${state.router.lanIp}:3000/`)}" target="_blank" rel="noreferrer">AdGuardHome</a>` : ''}
    </div>
  `;
}

function renderPanel() {
  const id = steps[state.step].id;
  if (id === 'account')
    return renderAccount();
  if (id === 'vpn')
    return renderVpn();
  if (id === 'adguard')
    return renderAdguard();
  if (id === 'tailscale')
    return renderTailscale();
  return renderReview();
}

function renderErrors() {
  if (!state.errors.length)
    return '';
  return `
    <div class="errors">
      ${state.errors.map(error => `<div>${escapeHtml(error)}</div>`).join('')}
    </div>
  `;
}

function render() {
  if (!state.ready) {
    app.innerHTML = '<div class="setup"><div class="content"><h1>Loading setup assistant</h1></div></div>';
    return;
  }

  const step = steps[state.step];
  app.innerHTML = `
    <section class="setup">
      <aside class="sidebar">
        <div class="brand">
          <div class="mark">OW</div>
          <div>
            <div class="brand-title">OpenWrt Setup</div>
            <div class="brand-subtitle">${escapeHtml(state.router.firmware)}</div>
          </div>
        </div>
        <nav class="steps" aria-label="Setup steps">
          ${steps.map((item, index) => `
            <button
              class="step-button ${index < state.step ? 'done' : ''}"
              data-step="${index}"
              ${index === state.step ? 'aria-current="step"' : ''}
              ${canJumpTo(index) ? '' : 'disabled'}>
              <span class="step-dot">${index < state.step ? '' : index + 1}</span>
              <span>${escapeHtml(item.label)}</span>
            </button>
          `).join('')}
        </nav>
        <div class="target">
          Target LAN<br>
          <strong>http://${escapeHtml(state.router.lanIp)}</strong><br>
          ${escapeHtml(state.router.hostname)}
        </div>
      </aside>
      <section class="content">
        <header class="headline">
          <div class="eyebrow">${escapeHtml(step.eyebrow)}</div>
          <h1>${escapeHtml(step.title)}</h1>
          <p class="lede">${escapeHtml(step.lede)}</p>
        </header>
        <div class="panel">
          ${renderErrors()}
          ${renderPanel()}
        </div>
        <footer class="footer">
          <button class="text-button" data-action="reset-preview" ${state.applied ? '' : 'disabled'}>Start over</button>
          <div class="footer-actions">
            <button class="secondary" data-action="back" ${state.step === 0 ? 'disabled' : ''}>Back</button>
            ${
              state.step === steps.length - 1
                ? `<button class="primary" data-action="apply" ${state.applying || state.applied ? 'disabled' : ''}>Apply setup</button>`
                : '<button class="primary" data-action="next">Continue</button>'
            }
          </div>
        </footer>
      </section>
    </section>
  `;
}

function bindEvents() {
  app.addEventListener('input', event => {
    const path = event.target.dataset.path;
    if (path)
      updateNested(path, event.target.value);

    if (event.target.id === 'filter-search') {
      state.filterQuery = event.target.value;
      refreshAdguardFilterList();
    }
  });

  app.addEventListener('change', event => {
    if (event.target.name === 'vpn-enabled')
      setNested('vpn.enabled', event.target.value === '1');

    if (event.target.name === 'adguard-enabled')
      setNested('adguard.enabled', event.target.value === '1');

    if (event.target.name === 'tailscale-enabled')
      setNested('tailscale.enabled', event.target.value === '1');

    if (event.target.dataset.filterId)
      toggleFilter(event.target.dataset.filterId, event.target.checked);
  });

  app.addEventListener('click', event => {
    const button = event.target.closest('button');
    if (!button)
      return;

    if (button.dataset.step) {
      goTo(Number(button.dataset.step));
      return;
    }

    const action = button.dataset.action;
    if (action === 'next')
      nextStep();
    if (action === 'back')
      previousStep();
    if (action === 'router-defaults')
      useRouterDefaults();
    if (action === 'select-visible')
      selectVisibleFilters();
    if (action === 'apply')
      applySetup();
    if (action === 'reset-preview') {
      state.applied = null;
      render();
    }
  });
}

async function applySetup() {
  const allErrors = steps.flatMap((_, index) => validateStep(index));
  if (allErrors.length) {
    state.errors = Array.from(new Set(allErrors));
    render();
    return;
  }

  state.applying = true;
  state.errors = [];
  render();

  try {
    const response = await fetch(apiUrl('apply'), {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(state.form)
    });
    const payload = await response.json();
    if (!payload.ok)
      throw new Error((payload.errors || ['Apply failed']).join(' '));
    state.applied = payload.data;
  }
  catch (error) {
    state.errors = [error.message];
  }
  finally {
    state.applying = false;
    render();
  }
}

async function bootstrap() {
  bindEvents();
  render();

  const response = await fetch(apiUrl('bootstrap'));
  const payload = await response.json();
  const data = payload.data || {};

  state.router = data.router || state.router;
  state.filters = data.adguard?.filters || [];
  state.adguardAvailable = !!data.adguard?.available;
  state.form.account.login = data.defaults?.accountLogin || state.form.account.login;
  state.form.vpn.enabled = data.defaults?.vpnEnabled ?? state.form.vpn.enabled;
  state.form.adguard.enabled = state.adguardAvailable && !!data.defaults?.adguardEnabled;
  state.form.tailscale.enabled = data.defaults?.tailscaleEnabled ?? state.form.tailscale.enabled;
  state.form.tailscale.loginServer = data.defaults?.tailscaleLoginServer || state.form.tailscale.loginServer;
  state.form.adguard.selectedFilterIds = state.filters
    .filter(filter => filter.enabled)
    .map(filter => filter.id);
  state.ready = true;
  render();
}

bootstrap().catch(error => {
  state.ready = true;
  state.errors = [error.message];
  render();
});
