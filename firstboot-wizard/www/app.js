const steps = [
  {
    id: 'account',
    label: 'Account',
    eyebrow: 'First boot',
    title: 'Create the router login',
    lede: 'Set the SSH credentials that will protect the router after the assistant finishes.'
  },
  {
    id: 'wifi',
    label: 'Wi-Fi',
    eyebrow: 'Wireless',
    title: 'Configure wireless networks',
    lede: 'Choose the bands, network name, security, and radio behavior for detected Wi-Fi hardware.'
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
  progress: {
    inProgress: false,
    completedPhases: []
  },
  devPreview: false,
  applying: false,
  applied: null,
  filterQuery: '',
  router: {
    hostname: 'openwrt-fin0',
    lanIp: '10.77.0.1',
    firmware: 'OpenWrt 24.10.5 x86/64'
  },
  filters: [],
  wifiRadios: [],
  form: {
    account: {
      login: 'root',
      password: '',
      passwordConfirm: '',
      authorizedKeys: ''
    },
    wifi: {
      enabled: false,
      enable2g: true,
      enable5g: true,
      ssid: 'OpenWrt',
      security: 'sae-mixed',
      password: '',
      country: 'US',
      channel2g: 'auto',
      channel5g: 'auto',
      hidden: false,
      isolate: false
    },
    vpn: {
      enabled: true,
      vlessUrl: ''
    },
    adguard: {
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
const DRAFT_KEY = 'openwrt-firstboot-draft-v1';
const SECRET_DRAFT_KEY = 'openwrt-firstboot-secrets-v1';
const devPreviewToken = new URLSearchParams(window.location.hash.slice(1)).get('dev') || '';

function apiUrl(action) {
  if (routerApiMode)
    return `/cgi-bin/firstboot-setup?action=${encodeURIComponent(action)}`;
  return `/api/${encodeURIComponent(action)}`;
}

async function authorizeDevPreview() {
  if (!devPreviewToken)
    return false;
  try {
    const response = await fetch('/cgi-bin/router-prep?action=authorize', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ token: devPreviewToken }),
      cache: 'no-store'
    });
    const payload = await response.json();
    return !!payload.ok;
  }
  catch (_) {
    return false;
  }
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

function phaseDone(phase) {
  return state.progress.completedPhases.includes(phase);
}

function saveDraft() {
  const durable = {
    step: state.step,
    account: {
      login: state.form.account.login,
      authorizedKeys: state.form.account.authorizedKeys
    },
    wifi: {
      ...state.form.wifi,
      password: ''
    },
    vpn: {
      enabled: state.form.vpn.enabled
    },
    adguard: {
      selectedFilterIds: state.form.adguard.selectedFilterIds
    },
    tailscale: {
      enabled: state.form.tailscale.enabled,
      loginServer: state.form.tailscale.loginServer
    }
  };
  const secrets = {
    accountPassword: state.form.account.password,
    accountPasswordConfirm: state.form.account.passwordConfirm,
    wifiPassword: state.form.wifi.password,
    vlessUrl: state.form.vpn.vlessUrl,
    tailscaleAuthKey: state.form.tailscale.authKey
  };

  try {
    localStorage.setItem(DRAFT_KEY, JSON.stringify(durable));
    sessionStorage.setItem(SECRET_DRAFT_KEY, JSON.stringify(secrets));
  }
  catch (_) {
    // Storage may be unavailable in private browsing.
  }
}

function clearDraft() {
  try {
    localStorage.removeItem(DRAFT_KEY);
    sessionStorage.removeItem(SECRET_DRAFT_KEY);
  }
  catch (_) {}
}

function restoreDraft() {
  try {
    const durable = JSON.parse(localStorage.getItem(DRAFT_KEY) || 'null');
    const secrets = JSON.parse(sessionStorage.getItem(SECRET_DRAFT_KEY) || 'null');

    if (durable) {
      state.step = Math.max(0, Math.min(steps.length - 1, Number(durable.step) || 0));
      state.form.account.login = durable.account?.login || state.form.account.login;
      state.form.account.authorizedKeys = durable.account?.authorizedKeys || '';
      Object.assign(state.form.wifi, durable.wifi || {});
      state.form.vpn.enabled = durable.vpn?.enabled ?? state.form.vpn.enabled;
      state.form.adguard.selectedFilterIds = Array.isArray(durable.adguard?.selectedFilterIds)
        ? durable.adguard.selectedFilterIds.filter(id => state.filters.some(filter => filter.id === id))
        : state.form.adguard.selectedFilterIds;
      state.form.tailscale.enabled = durable.tailscale?.enabled ?? state.form.tailscale.enabled;
      state.form.tailscale.loginServer = durable.tailscale?.loginServer || state.form.tailscale.loginServer;
    }

    if (secrets) {
      state.form.account.password = secrets.accountPassword || '';
      state.form.account.passwordConfirm = secrets.accountPasswordConfirm || '';
      state.form.wifi.password = secrets.wifiPassword || '';
      state.form.vpn.vlessUrl = secrets.vlessUrl || '';
      state.form.tailscale.authKey = secrets.tailscaleAuthKey || '';
    }
  }
  catch (_) {
    clearDraft();
  }
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
  saveDraft();
  clearErrorsInPlace();
}

function setNested(path, value) {
  writeNested(path, value);
  state.errors = [];
  saveDraft();
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

  if (id === 'wifi' && form.wifi.enabled && !phaseDone('wifi')) {
    if (!state.wifiRadios.length)
      errors.push('No compatible Wi-Fi radio was detected.');
    if (!form.wifi.enable2g && !form.wifi.enable5g)
      errors.push('Enable at least one Wi-Fi band.');
    if (!form.wifi.ssid.trim())
      errors.push('Wi-Fi network name is required.');
    if (form.wifi.ssid.length > 32)
      errors.push('Wi-Fi network name must be 32 characters or fewer.');
    if (form.wifi.security !== 'none' && form.wifi.password.length < 8)
      errors.push('Wi-Fi password must be at least 8 characters.');
  }

  if (id === 'vpn' && form.vpn.enabled && !phaseDone('vpn')) {
    if (!form.vpn.vlessUrl.trim().startsWith('vless://'))
      errors.push('Paste a valid VLESS link or disable VPN for first boot.');
  }

  if (id === 'adguard' && selectedFilters().length === 0 && !phaseDone('adguard'))
    errors.push('Select at least one AdGuard blocklist.');

  if (id === 'tailscale' && form.tailscale.enabled && !phaseDone('tailscale')) {
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
  saveDraft();
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
    saveDraft();
    render();
  }
}

function previousStep() {
  if (state.step > 0) {
    state.step -= 1;
    state.errors = [];
    saveDraft();
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
  saveDraft();
  clearErrorsInPlace();
  refreshAdguardFilterList();
}

function useRouterDefaults() {
  state.form.adguard.selectedFilterIds = state.filters
    .filter(filter => filter.enabled)
    .map(filter => filter.id);
  state.filterQuery = '';
  state.errors = [];
  saveDraft();
  const search = document.querySelector('#filter-search');
  if (search)
    search.value = '';
  refreshAdguardFilterList();
}

function selectVisibleFilters() {
  const selected = new Set(state.form.adguard.selectedFilterIds);
  filteredFilters().forEach(filter => selected.add(filter.id));
  state.form.adguard.selectedFilterIds = Array.from(selected);
  saveDraft();
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

function selectField({ id, label, value, path, options, hint = '' }) {
  return `
    <div class="field">
      <label for="${id}">${escapeHtml(label)}</label>
      <select id="${id}" data-path="${attr(path)}">
        ${options.map(option => `
          <option value="${attr(option.value)}" ${option.value === value ? 'selected' : ''}>
            ${escapeHtml(option.label)}
          </option>
        `).join('')}
      </select>
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

function renderWifi() {
  const wifi = state.form.wifi;
  const has2g = state.wifiRadios.some(radio => radio.band === '2g');
  const has5g = state.wifiRadios.some(radio => radio.band === '5g');
  const radioSummary = state.wifiRadios.length
    ? state.wifiRadios.map(radio => `${radio.label} (${radio.device})`).join(', ')
    : 'No compatible Wi-Fi radios detected';

  return `
    <div class="choice-set">
      <label class="choice-row">
        <input type="radio" name="wifi-enabled" value="0" ${!wifi.enabled ? 'checked' : ''}>
        <span>
          <span class="choice-title">Leave Wi-Fi disabled</span>
          <span class="choice-detail">Ethernet remains available and wireless can be configured later in LuCI.</span>
        </span>
      </label>
      <label class="choice-row ${state.wifiRadios.length ? '' : 'muted'}">
        <input type="radio" name="wifi-enabled" value="1" ${wifi.enabled ? 'checked' : ''} ${state.wifiRadios.length ? '' : 'disabled'}>
        <span>
          <span class="choice-title">Configure Wi-Fi</span>
          <span class="choice-detail">${escapeHtml(radioSummary)}</span>
        </span>
      </label>
    </div>
    <div class="form-grid ${wifi.enabled ? '' : 'hidden'}">
      ${inputField({
        id: 'wifi-ssid',
        label: 'Network name',
        value: wifi.ssid,
        path: 'wifi.ssid',
        autocomplete: 'off'
      })}
      ${selectField({
        id: 'wifi-security',
        label: 'Security',
        value: wifi.security,
        path: 'wifi.security',
        options: [
          { value: 'sae-mixed', label: 'WPA2/WPA3 Personal' },
          { value: 'psk2', label: 'WPA2 Personal' },
          { value: 'sae', label: 'WPA3 Personal' },
          { value: 'none', label: 'Open network' }
        ]
      })}
      ${inputField({
        id: 'wifi-password',
        label: 'Wi-Fi password',
        type: 'password',
        value: wifi.password,
        path: 'wifi.password',
        autocomplete: 'new-password',
        hint: wifi.security === 'none' ? 'Not used for an open network.' : 'At least 8 characters.'
      })}
      ${inputField({
        id: 'wifi-country',
        label: 'Country code',
        value: wifi.country,
        path: 'wifi.country',
        hint: 'Two-letter regulatory code, for example US, DE, or RU.'
      })}
      ${has2g ? selectField({
        id: 'wifi-channel-2g',
        label: '2.4 GHz channel',
        value: wifi.channel2g,
        path: 'wifi.channel2g',
        options: [
          { value: 'auto', label: 'Automatic' },
          ...Array.from({ length: 13 }, (_, index) => {
            const channel = String(index + 1);
            return { value: channel, label: channel };
          })
        ]
      }) : ''}
      ${has5g ? selectField({
        id: 'wifi-channel-5g',
        label: '5 GHz channel',
        value: wifi.channel5g,
        path: 'wifi.channel5g',
        options: [
          { value: 'auto', label: 'Automatic' },
          ...['36', '40', '44', '48', '100', '104', '108', '112', '116', '120', '124', '128', '132', '136', '140', '149', '153', '157', '161']
            .map(channel => ({ value: channel, label: channel }))
        ]
      }) : ''}
      <div class="field full">
        <label>Wireless bands</label>
        <div class="choice-set compact">
          <label class="choice-row">
            <input type="checkbox" data-path="wifi.enable2g" ${wifi.enable2g ? 'checked' : ''} ${has2g ? '' : 'disabled'}>
            <span><span class="choice-title">2.4 GHz</span></span>
          </label>
          <label class="choice-row">
            <input type="checkbox" data-path="wifi.enable5g" ${wifi.enable5g ? 'checked' : ''} ${has5g ? '' : 'disabled'}>
            <span><span class="choice-title">5 GHz</span></span>
          </label>
          <label class="choice-row">
            <input type="checkbox" data-path="wifi.hidden" ${wifi.hidden ? 'checked' : ''}>
            <span><span class="choice-title">Hide network name</span></span>
          </label>
          <label class="choice-row">
            <input type="checkbox" data-path="wifi.isolate" ${wifi.isolate ? 'checked' : ''}>
            <span><span class="choice-title">Isolate wireless clients</span></span>
          </label>
        </div>
      </div>
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
        <label for="vless-url">VLESS link</label>
        <input
          id="vless-url"
          type="text"
          value="${attr(vpn.vlessUrl)}"
          data-path="vpn.vlessUrl"
          placeholder="vless://...">
        <div class="hint">The final router helper will import this into the VPN panel profile store.</div>
      </div>
    </div>
  `;
}

function renderAdguard() {
  return `
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
    ${state.applying ? `
      <div class="apply-progress" role="status" aria-live="polite">
        <span class="spinner" aria-hidden="true"></span>
        <span>
          <span class="apply-progress-title">Applying setup</span>
          <span class="apply-progress-detail">Writing router settings and validating services. Keep this page open.</span>
        </span>
      </div>
    ` : ''}
    <div class="review">
      ${reviewRow('Router', `${state.router.hostname} on ${state.router.lanIp}`)}
      ${reviewRow('SSH login', state.form.account.login)}
      ${reviewRow('SSH password', state.form.account.password ? 'Will be set' : 'Missing')}
      ${reviewRow('Wi-Fi', state.form.wifi.enabled
        ? `${state.form.wifi.ssid} (${[
          state.form.wifi.enable2g ? '2.4 GHz' : '',
          state.form.wifi.enable5g ? '5 GHz' : ''
        ].filter(Boolean).join(' + ')}, ${state.form.wifi.security})`
        : 'Disabled')}
      ${reviewRow('VPN', vpn.enabled ? 'Enabled with VLESS profile' : 'Disabled on first boot')}
      ${reviewRow('AdGuard filters', selected.map(filter => filter.name).join(', '))}
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
  const finishUrl = target => `${apiUrl('finish')}&target=${encodeURIComponent(target)}`;
  const luciUrl = finishUrl('luci');
  const vpnUrl = finishUrl('vpn');
  const adguardUrl = finishUrl('adguard');
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
      ${reviewRow('VPN panel', vpnUrl)}
      ${reviewRow('AdGuard', adguardUrl)}
    </div>
    <div class="link-row">
      <a href="${attr(luciUrl)}" target="_blank" rel="noreferrer">LuCI</a>
      <a href="${attr(vpnUrl)}" target="_blank" rel="noreferrer">VPN panel</a>
      <a href="${attr(adguardUrl)}" target="_blank" rel="noreferrer">AdGuardHome</a>
    </div>
  `;
}

function renderPanel() {
  const id = steps[state.step].id;
  if (id === 'account')
    return renderAccount();
  if (id === 'wifi')
    return renderWifi();
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
          ${state.devPreview ? '<div class="notice">Developer preview. Applying customer setup is disabled.</div>' : ''}
          ${renderErrors()}
          ${renderPanel()}
        </div>
        <footer class="footer">
          <button class="text-button" data-action="reset-preview">Start over</button>
          <div class="footer-actions">
            <button class="secondary" data-action="back" ${state.step === 0 ? 'disabled' : ''}>Back</button>
            ${
              state.step === steps.length - 1
                ? `<button class="primary" data-action="apply" ${state.applying || state.applied || state.devPreview ? 'disabled' : ''}>${state.applying ? 'Applying setup' : 'Apply setup'}</button>`
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
    if (path && event.target.type !== 'checkbox')
      updateNested(path, event.target.value);

    if (event.target.id === 'filter-search') {
      state.filterQuery = event.target.value;
      refreshAdguardFilterList();
    }
  });

  app.addEventListener('change', event => {
    if (event.target.dataset.path && event.target.type === 'checkbox')
      setNested(event.target.dataset.path, event.target.checked);
    else if (event.target.dataset.path && event.target.tagName === 'SELECT')
      setNested(event.target.dataset.path, event.target.value);

    if (event.target.name === 'wifi-enabled')
      setNested('wifi.enabled', event.target.value === '1');

    if (event.target.name === 'vpn-enabled')
      setNested('vpn.enabled', event.target.value === '1');

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
      clearDraft();
      state.applied = null;
      window.location.reload();
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
    clearDraft();
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

  const [bootstrapResponse, statusResponse] = await Promise.all([
    fetch(apiUrl('bootstrap'), { cache: 'no-store' }),
    fetch(apiUrl('status'), { cache: 'no-store' })
  ]);
  const payload = await bootstrapResponse.json();
  const status = await statusResponse.json();
  state.devPreview = await authorizeDevPreview();
  if (status.complete && routerApiMode && !state.devPreview) {
    window.location.replace('/cgi-bin/luci/');
    return;
  }
  const data = payload.data || {};

  state.router = data.router || state.router;
  state.filters = data.adguard?.filters || [];
  state.wifiRadios = data.wifi?.radios || [];
  state.form.account.login = data.defaults?.accountLogin || state.form.account.login;
  state.form.wifi.enabled = data.defaults?.wifiEnabled ?? state.form.wifi.enabled;
  state.form.wifi.ssid = data.defaults?.wifiSsid || state.form.wifi.ssid;
  state.form.wifi.country = data.defaults?.wifiCountry || state.form.wifi.country;
  state.form.vpn.enabled = data.defaults?.vpnEnabled ?? state.form.vpn.enabled;
  state.form.tailscale.enabled = data.defaults?.tailscaleEnabled ?? state.form.tailscale.enabled;
  state.form.tailscale.loginServer = data.defaults?.tailscaleLoginServer || state.form.tailscale.loginServer;
  state.form.adguard.selectedFilterIds = state.filters
    .filter(filter => filter.enabled)
    .map(filter => filter.id);
  state.progress = {
    inProgress: !!status.inProgress,
    completedPhases: Array.isArray(status.completedPhases) ? status.completedPhases : []
  };
  restoreDraft();
  if (state.progress.inProgress)
    state.errors = ['Setup was interrupted. Completed service phases will be skipped; root credentials will be verified again.'];
  state.ready = true;
  render();
}

bootstrap().catch(error => {
  state.ready = true;
  state.errors = [error.message];
  render();
});
