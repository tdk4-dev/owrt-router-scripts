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
    title: 'Optional DNS filtering',
    lede: 'Skip AdGuardHome on memory-constrained routers, or configure it when the router image already includes it.'
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
  adguardAvailable: true,
  adguardCanInstall: false,
  adguardInstalling: false,
  adguardStorage: null,
  form: {
    router: {
      hostname: 'openwrt-fin0'
    },
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
const resetRecoveryMode = routerApiMode && new URLSearchParams(window.location.search).get('reset') === '1';
const DRAFT_KEY = 'openwrt-firstboot-draft-v1';
const SECRET_DRAFT_KEY = 'openwrt-firstboot-secrets-v1';
const RESET_STARTED_KEY = 'premier-router-reset-started-at';
const devPreviewToken = new URLSearchParams(window.location.hash.slice(1)).get('dev') || '';
let resetPollTimer = null;
let resetRecovery = {
  phase: 'requested',
  detail: 'The router accepted the reset request. Preparing to stop services.',
  elapsed: 0,
  failed: false
};

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
    router: {
      hostname: state.form.router.hostname
    },
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
      enabled: state.form.adguard.enabled,
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
      state.form.router.hostname = durable.router?.hostname || state.form.router.hostname;
      state.form.account.login = durable.account?.login || state.form.account.login;
      state.form.account.authorizedKeys = durable.account?.authorizedKeys || '';
      Object.assign(state.form.wifi, durable.wifi || {});
      state.form.vpn.enabled = durable.vpn?.enabled ?? state.form.vpn.enabled;
      state.form.adguard.enabled = durable.adguard?.enabled ?? state.form.adguard.enabled;
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
    const hostname = form.router.hostname.trim();
    if (!hostname)
      errors.push('Router name is required.');
    if (hostname.length > 63 || !/^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$/.test(hostname))
      errors.push('Router name must be 1 to 63 letters, numbers, or hyphens, and cannot begin or end with a hyphen.');
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
    if (form.wifi.security !== 'none' && form.wifi.password.length > 63)
      errors.push('Wi-Fi password must be 63 characters or fewer.');
    if (!['sae-mixed', 'psk2', 'sae', 'none'].includes(form.wifi.security))
      errors.push('Choose a supported Wi-Fi security mode.');
    if (!/^[A-Za-z]{2}$/.test(form.wifi.country))
      errors.push('Wi-Fi country code must contain two letters.');
    if (!/^(?:auto|[1-9]|1[0-3])$/.test(String(form.wifi.channel2g)))
      errors.push('Choose a valid 2.4 GHz channel.');
    if (!/^(?:auto|[0-9]{2}|1[0-9]{2})$/.test(String(form.wifi.channel5g)))
      errors.push('Choose a valid 5 GHz channel.');
  }

  if (id === 'vpn' && form.vpn.enabled && !phaseDone('vpn')) {
    const vpnUrl = form.vpn.vlessUrl.trim();
    if (!vpnUrl.startsWith('vless://') && !vpnUrl.startsWith('https://'))
      errors.push('Paste a valid VLESS link or HTTPS subscription link, or disable VPN for first boot.');
  }

  if (id === 'adguard' && state.form.adguard.enabled && state.adguardAvailable && selectedFilters().length === 0 && !phaseDone('adguard'))
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
        id: 'router-hostname',
        label: 'Router name',
        value: state.form.router.hostname,
        path: 'router.hostname',
        autocomplete: 'off',
        hint: 'Used as the OpenWrt hostname and, if enabled, the Tailscale device name.'
      })}
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
          <span class="choice-detail">The router starts Xray, then verifies real internet access through the selected profile. An expired or unreachable link will not be accepted as connected.</span>
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

function formatBytes(value) {
  const bytes = Number(value || 0);
  if (!Number.isFinite(bytes) || bytes <= 0)
    return 'Unknown';
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  const index = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1);
  const amount = bytes / (1024 ** index);
  return `${amount >= 10 || index === 0 ? amount.toFixed(0) : amount.toFixed(1)} ${units[index]}`;
}

function clampPercent(value) {
  return Math.max(0, Math.min(100, Number(value) || 0));
}

function renderAdguardStorage() {
  const storage = state.adguardStorage;
  if (!storage || !storage.totalBytes)
    return '<div class="notice danger">Router storage could not be measured safely, so AdGuardHome installation is unavailable.</div>';

  const usedPercent = clampPercent(storage.usedPercent);
  const packagePercent = clampPercent((Number(storage.estimatedInstallBytes || 0) / Number(storage.totalBytes)) * 100);
  const visiblePackagePercent = packagePercent > 0 ? Math.max(packagePercent, 1.5) : 0;
  const projected = Math.max(0, Number(storage.projectedUsedPercent) || 0);
  const risk = storage.risk || (projected > 95 ? 'blocked' : (projected >= 90 ? 'warning' : 'safe'));
  const message = risk === 'blocked'
    ? `Installation would fill approximately ${projected.toFixed(1)}% of persistent storage. AdGuardHome cannot be installed safely.`
    : (risk === 'warning'
      ? `Installation would fill approximately ${projected.toFixed(1)}% of persistent storage. This leaves little room for updates, logs, and configuration.`
      : `After installation, approximately ${Math.max(0, 100 - projected).toFixed(1)}% of persistent storage should remain free.`);

  return `
    <section class="storage-card" aria-label="Writable flash and disk storage estimate">
      <div class="storage-heading">
        <div>
          <strong>Writable flash / disk storage</strong>
          <div>${formatBytes(storage.freeBytes)} available of ${formatBytes(storage.totalBytes)}</div>
        </div>
        <span class="badge ${risk === 'safe' ? 'good' : 'warn'}">${projected.toFixed(1)}% projected</span>
      </div>
      <div class="storage-bar" role="img" aria-label="${usedPercent.toFixed(1)} percent used; AdGuardHome adds approximately ${formatBytes(storage.estimatedInstallBytes)}">
        <span class="storage-used" style="width:${usedPercent}%"></span>
        <span class="storage-adguard" style="width:${Math.min(visiblePackagePercent, Math.max(0, 100 - usedPercent))}%"></span>
      </div>
      <div class="storage-legend">
        <span><i class="legend-used"></i>Used ${formatBytes(storage.usedBytes)}</span>
        <span><i class="legend-adguard"></i>AdGuardHome ≈ ${formatBytes(storage.estimatedInstallBytes)}</span>
        <span><i class="legend-free"></i>Currently free ${formatBytes(storage.freeBytes)}</span>
      </div>
      <div class="hint">This is package storage on the writable root filesystem. LuCI's Memory total is router RAM, which is a separate resource.</div>
      <div class="notice ${risk === 'blocked' ? 'danger' : (risk === 'warning' ? 'warn' : '')}">${escapeHtml(message)}</div>
    </section>
  `;
}

function renderAdguard() {
  if (!state.adguardAvailable) {
    return `
      ${renderAdguardStorage()}
      <div class="install-card">
        <div>
          <strong>AdGuardHome is not installed</strong>
          <div class="hint">Install it from the signed OpenWrt package feed, or continue without changing DNS. Installation never runs a global package upgrade.</div>
        </div>
        <button class="primary" data-action="install-adguard" ${state.adguardInstalling || !state.adguardCanInstall ? 'disabled' : ''}>
          ${state.adguardInstalling ? 'Installing AdGuardHome…' : `Install AdGuardHome (≈ ${formatBytes(state.adguardStorage?.estimatedInstallBytes)})`}
        </button>
      </div>
    `;
  }
  return `
    <div class="choice-set">
      <label class="choice-row">
        <input type="radio" name="adguard-enabled" value="0" ${!state.form.adguard.enabled ? 'checked' : ''}>
        <span>
          <span class="choice-title">Skip AdGuardHome</span>
          <span class="choice-detail">Recommended for routers with limited memory. Existing AdGuard and DNS state are left unchanged.</span>
        </span>
      </label>
      <label class="choice-row">
        <input type="radio" name="adguard-enabled" value="1" ${state.form.adguard.enabled ? 'checked' : ''}>
        <span>
          <span class="choice-title">Enable and configure AdGuardHome</span>
          <span class="choice-detail">Uses additional memory and requires AdGuardHome to be included in the router image.</span>
        </span>
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
          <span class="choice-title">Leave Tailscale disconnected</span>
          <span class="choice-detail">Tailscale is already installed. Connect it later from Network → Tailscale in LuCI.</span>
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
      ${reviewRow('Router', `${state.form.router.hostname} on ${state.router.lanIp}`)}
      ${reviewRow('SSH login', state.form.account.login)}
      ${reviewRow('SSH password', state.form.account.password ? 'Will be set' : 'Missing')}
      ${reviewRow('Wi-Fi', state.form.wifi.enabled
        ? `${state.form.wifi.ssid} (${[
          state.form.wifi.enable2g ? '2.4 GHz' : '',
          state.form.wifi.enable5g ? '5 GHz' : ''
        ].filter(Boolean).join(' + ')}, ${state.form.wifi.security})`
        : 'Disabled')}
      ${reviewRow('VPN', vpn.enabled ? 'Enabled with VLESS profile' : 'Disabled on first boot')}
      ${reviewRow('AdGuardHome', state.form.adguard.enabled && state.adguardAvailable ? `Enabled with ${selected.length} filters` : 'Skipped')}
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
  const adguardUrl = finishUrl('adguard');
  const adguardEnabled = !!apply.preview?.adguard?.enabled && !!apply.preview?.adguard?.available;
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
      ${reviewRow('Apply ID', apply.id)}
      ${reviewRow('Applied at', apply.appliedAt)}
      ${reviewRow('AdGuard', adguardEnabled ? 'Installed and configured' : 'Skipped')}
      ${reviewRow('Router reset', 'Available later in System -> Reset.')}
    </div>
    <div class="link-row">
      <a href="${attr(luciUrl)}">Open LuCI panel</a>
      ${adguardEnabled ? `<a href="${attr(adguardUrl)}">Open AdGuardHome</a>` : ''}
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

function renderBrandMark() {
  return '<div class="mark burger-mark" role="img" aria-label="Burger">🍔</div>';
}

function resetPhaseIndex(phase) {
  if (phase === 'stopping-services') return 1;
  if (phase === 'clearing-configuration' || phase === 'resetting-storage') return 2;
  if (phase === 'rebooting' || phase === 'offline') return 3;
  if (phase === 'ready') return 4;
  return 0;
}

function formatElapsed(seconds) {
  const minutes = Math.floor(seconds / 60);
  const remainder = seconds % 60;
  return minutes ? `${minutes}m ${String(remainder).padStart(2, '0')}s` : `${remainder}s`;
}

function renderResetRecovery() {
  const current = resetPhaseIndex(resetRecovery.phase);
  const phases = [
    ['Request accepted', 'The router scheduled a protected reset job.'],
    ['Stopping services', 'VPN, Tailscale, and DNS services are stopped before configuration is erased.'],
    ['Clearing configuration', 'Passwords, keys, network settings, and setup state are being reset.'],
    ['Restarting OpenWrt', 'The router can be offline for several minutes while storage is reset and OpenWrt boots.'],
    ['Setup ready', 'The fresh first-boot assistant is available.']
  ];
  app.innerHTML = `
    <section class="setup reset-recovery">
      <aside class="sidebar">
        <div class="brand">
          ${renderBrandMark()}
          <div>
            <div class="brand-title">OpenWrt Setup</div>
            <div class="brand-subtitle">Reset recovery</div>
          </div>
        </div>
        <div class="target">
          Do not power off the router.<br>
          This page is safe to reload.
        </div>
      </aside>
      <section class="content reset-content">
        <header class="headline">
          <div class="eyebrow">Router reset</div>
          <h1>${resetRecovery.failed ? 'Reset needs attention' : current === 4 ? 'Setup is ready' : 'Resetting router'}</h1>
          <p class="lede">${escapeHtml(resetRecovery.detail)}</p>
        </header>
        <div class="panel">
          <div class="reset-progress" role="status" aria-live="polite">
            <div class="reset-progress-heading">
              <strong>${resetRecovery.failed ? 'Stopped' : current === 4 ? 'Complete' : 'In progress'}</strong>
              <span>Elapsed ${formatElapsed(resetRecovery.elapsed)}</span>
            </div>
            <div class="reset-progress-bar"><span style="width:${Math.max(8, ((current + 1) / phases.length) * 100)}%"></span></div>
            <ol class="reset-phase-list">
              ${phases.map((phase, index) => `
                <li class="${index < current ? 'done' : index === current ? 'active' : ''}">
                  <span>${index < current ? '✓' : index + 1}</span>
                  <div><strong>${phase[0]}</strong><small>${phase[1]}</small></div>
                </li>
              `).join('')}
            </ol>
          </div>
          ${resetRecovery.failed ? '<div class="errors"><div>The reset command reported a failure before reboot. The router was not declared ready. Use the serial console or retry from LuCI after restoring access.</div></div>' : ''}
          <div class="notice">Keep this tab open or reload it at any time. Losing the old LuCI password during reset is expected; this public page does not require that session.</div>
          <div><button class="secondary" data-action="check-reset">Check now</button></div>
        </div>
      </section>
    </section>
  `;
}

function resetStartedAt() {
  try {
    const value = Number(localStorage.getItem(RESET_STARTED_KEY));
    if (Number.isFinite(value) && value > 0)
      return value;
    localStorage.setItem(RESET_STARTED_KEY, String(Date.now()));
  }
  catch (_) {}
  return Date.now();
}

const resetStarted = resetRecoveryMode ? resetStartedAt() : 0;

function scheduleResetPoll(delay = 2500) {
  window.clearTimeout(resetPollTimer);
  resetPollTimer = window.setTimeout(pollResetRecovery, delay);
}

async function pollResetRecovery() {
  resetRecovery.elapsed = Math.max(0, Math.floor((Date.now() - resetStarted) / 1000));
  try {
    const response = await fetch(`${apiUrl('status')}&_=${Date.now()}`, { cache: 'no-store' });
    if (!response.ok)
      throw new Error('offline');
    const status = await response.json();
    const phase = status.reset?.state || 'idle';
    if (status.ok && status.complete === false && phase === 'idle') {
      resetRecovery.phase = 'ready';
      resetRecovery.detail = 'OpenWrt restarted with a fresh setup state. Opening the assistant now.';
      resetRecovery.failed = false;
      renderResetRecovery();
      try { localStorage.removeItem(RESET_STARTED_KEY); } catch (_) {}
      window.setTimeout(() => window.location.replace('/setup/?v=0.8.0-ux-health-3'), 1200);
      return;
    }
    resetRecovery.phase = phase === 'failed' ? 'resetting-storage' : phase;
    resetRecovery.failed = phase === 'failed';
    if (phase === 'stopping-services')
      resetRecovery.detail = 'Router services are stopping safely before configuration is erased.';
    else if (phase === 'clearing-configuration')
      resetRecovery.detail = 'Credentials and writable router configuration are being removed.';
    else if (phase === 'resetting-storage')
      resetRecovery.detail = 'OpenWrt is resetting writable storage. This can take several minutes on a VM or slow flash.';
    else if (phase === 'rebooting')
      resetRecovery.detail = 'The reset completed and OpenWrt is restarting.';
    else if (phase === 'failed')
      resetRecovery.detail = 'OpenWrt reported that the storage reset command failed. Automatic reboot was stopped.';
    else
      resetRecovery.detail = 'The router accepted the reset request and is preparing the reset job.';
  }
  catch (_) {
    resetRecovery.phase = 'offline';
    resetRecovery.failed = false;
    resetRecovery.detail = 'The router is temporarily offline while OpenWrt restarts. This is expected; checking automatically.';
  }
  renderResetRecovery();
  if (!resetRecovery.failed)
    scheduleResetPoll();
}

function render() {
  if (resetRecoveryMode) {
    renderResetRecovery();
    return;
  }
  if (!state.ready) {
    app.innerHTML = `
      <section class="setup">
        <aside class="sidebar">
          <div class="brand">
            ${renderBrandMark()}
            <div>
              <div class="brand-title">OpenWrt Setup</div>
              <div class="brand-subtitle">OpenWrt 24.10.5 x86/64</div>
            </div>
          </div>
          <div class="target">
            <div>Target LAN</div>
            <strong>http://10.77.0.1</strong>
            <div>openwrt-fin0</div>
          </div>
        </aside>
        <div class="content loading-content">
          <header class="headline">
            <div class="eyebrow">Setup</div>
            <h1>Loading setup assistant</h1>
            <p class="lede">Waiting for the router to finish preparing the first-boot flow.</p>
          </header>
          <div class="loading-state">
            <div class="spinner" aria-hidden="true"></div>
            <div>
              <strong>Preparing setup</strong>
              <span>Keep this tab open while the router comes back online.</span>
            </div>
          </div>
        </div>
      </section>
    `;
    return;
  }

  const step = steps[state.step];
  app.innerHTML = `
    <section class="setup">
      <aside class="sidebar">
        <div class="brand">
          ${renderBrandMark()}
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
              <span class="step-dot">${index + 1}</span>
              <span>${escapeHtml(item.label)}</span>
            </button>
          `).join('')}
        </nav>
        <div class="target">
          Target LAN<br>
          <strong>http://${escapeHtml(state.router.lanIp)}</strong><br>
          ${escapeHtml(state.form.router.hostname)}
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
        ${state.applied ? '' : `<footer class="footer">
          <button class="text-button" data-action="reset-preview">Start over</button>
          <div class="footer-actions">
            <button class="secondary" data-action="back" ${state.step === 0 ? 'disabled' : ''}>Back</button>
            ${
              state.step === steps.length - 1
                ? `<button class="primary" data-action="apply" ${state.applying || state.applied || state.devPreview ? 'disabled' : ''}>${state.applying ? 'Applying setup' : 'Apply setup'}</button>`
                : '<button class="primary" data-action="next">Continue</button>'
            }
          </div>
        </footer>`}
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
    if (action === 'install-adguard')
      installAdguard();
    if (action === 'apply')
      applySetup();
    if (action === 'reset-preview') {
      clearDraft();
      state.applied = null;
      window.location.reload();
    }
    if (action === 'check-reset')
      pollResetRecovery();
  });
}

async function installAdguard() {
  if (state.adguardInstalling || !state.adguardCanInstall)
    return;

  state.adguardInstalling = true;
  state.errors = [];
  render();

  try {
    const response = await fetch(apiUrl('adguard-install'), {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: '{}'
    });
    const payload = await response.json();
    if (!payload.ok)
      throw new Error((payload.errors || [payload.error || 'AdGuardHome installation failed']).join(' '));
    const adguard = payload.data?.adguard || payload.data || {};
    state.adguardAvailable = !!adguard.available;
    state.adguardCanInstall = !!adguard.canInstall;
    state.adguardStorage = adguard.storage || state.adguardStorage;
    if (state.adguardAvailable) {
      state.form.adguard.enabled = true;
      if (!state.form.adguard.selectedFilterIds.length)
        useRouterDefaults();
    }
  }
  catch (error) {
    state.errors = [error.message];
  }
  finally {
    state.adguardInstalling = false;
    saveDraft();
    render();
  }
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

  if (resetRecoveryMode) {
    pollResetRecovery();
    return;
  }

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
  state.form.router.hostname = data.router?.hostname || state.form.router.hostname;
  state.filters = data.adguard?.filters || [];
  state.adguardAvailable = data.adguard?.available ?? true;
  state.adguardCanInstall = data.adguard?.canInstall ?? false;
  state.adguardStorage = data.adguard?.storage || null;
  state.wifiRadios = data.wifi?.radios || [];
  state.form.account.login = data.defaults?.accountLogin || state.form.account.login;
  state.form.wifi.enabled = data.defaults?.wifiEnabled ?? state.form.wifi.enabled;
  state.form.wifi.ssid = data.defaults?.wifiSsid || state.form.wifi.ssid;
  state.form.wifi.country = data.defaults?.wifiCountry || state.form.wifi.country;
  state.form.vpn.enabled = data.defaults?.vpnEnabled ?? state.form.vpn.enabled;
  state.form.adguard.enabled = data.defaults?.adguardEnabled ?? false;
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
  if (!state.adguardAvailable)
    state.form.adguard.enabled = false;
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
