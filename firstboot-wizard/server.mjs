import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { extname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';

const rootDir = fileURLToPath(new URL('.', import.meta.url));
const webDir = join(rootDir, 'www');
const port = Number(process.env.PORT || 8787);
const applyDelayMs = Number(process.env.APPLY_DELAY_MS || 0);

const adguardFilters = [
  {
    id: 'registry-1hosts-lite',
    name: '1Hosts (Lite)',
    url: 'https://adguardteam.github.io/HostlistsRegistry/assets/filter_24.txt',
    category: 'General',
    enabled: false
  },
  {
    id: 'registry-1hosts-mini',
    name: '1Hosts (mini)',
    url: 'https://adguardteam.github.io/HostlistsRegistry/assets/filter_38.txt',
    category: 'General',
    enabled: false
  },
  {
    id: '1',
    name: 'AdGuard DNS filter',
    url: 'https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt',
    category: 'General',
    enabled: true
  },
  {
    id: '1779019548',
    name: 'AdGuard DNS Popup Hosts filter',
    url: 'https://adguardteam.github.io/HostlistsRegistry/assets/filter_59.txt',
    category: 'General',
    enabled: true
  },
  {
    id: 'registry-awavenue',
    name: 'AWAvenue Ads Rule',
    url: 'https://adguardteam.github.io/HostlistsRegistry/assets/filter_53.txt',
    category: 'General',
    enabled: false
  },
  {
    id: 'registry-dan-pollock',
    name: "Dan Pollock's List",
    url: 'https://adguardteam.github.io/HostlistsRegistry/assets/filter_4.txt',
    category: 'General',
    enabled: false
  },
  {
    id: 'registry-hagezi-normal',
    name: "HaGeZi's Normal Blocklist",
    url: 'https://adguardteam.github.io/HostlistsRegistry/assets/filter_34.txt',
    category: 'General',
    enabled: false
  },
  {
    id: 'registry-hagezi-pro',
    name: "HaGeZi's Pro Blocklist",
    url: 'https://adguardteam.github.io/HostlistsRegistry/assets/filter_48.txt',
    category: 'General',
    enabled: false
  },
  {
    id: 'registry-hagezi-pro-plus',
    name: "HaGeZi's Pro++ Blocklist",
    url: 'https://adguardteam.github.io/HostlistsRegistry/assets/filter_50.txt',
    category: 'General',
    enabled: false
  },
  {
    id: '1779019549',
    name: "HaGeZi's Ultimate Blocklist",
    url: 'https://adguardteam.github.io/HostlistsRegistry/assets/filter_49.txt',
    category: 'General',
    enabled: true
  },
  {
    id: 'registry-oisd-small',
    name: 'OISD Blocklist Small',
    url: 'https://adguardteam.github.io/HostlistsRegistry/assets/filter_27.txt',
    category: 'General',
    enabled: false
  },
  {
    id: 'registry-oisd-big',
    name: 'OISD Blocklist Big',
    url: 'https://adguardteam.github.io/HostlistsRegistry/assets/filter_5.txt',
    category: 'General',
    enabled: false
  },
  {
    id: 'registry-peter-lowe',
    name: "Peter Lowe's Blocklist",
    url: 'https://adguardteam.github.io/HostlistsRegistry/assets/filter_3.txt',
    category: 'General',
    enabled: false
  },
  {
    id: 'registry-steven-black',
    name: "Steven Black's List",
    url: 'https://adguardteam.github.io/HostlistsRegistry/assets/filter_33.txt',
    category: 'General',
    enabled: false
  },
  {
    id: 'registry-dandelion-push',
    name: "Dandelion Sprout's Anti Push Notifications",
    url: 'https://adguardteam.github.io/HostlistsRegistry/assets/filter_39.txt',
    category: 'Other',
    enabled: false
  },
  {
    id: 'registry-dandelion-game',
    name: "Dandelion Sprout's Game Console Adblock List",
    url: 'https://adguardteam.github.io/HostlistsRegistry/assets/filter_6.txt',
    category: 'Other',
    enabled: false
  },
  {
    id: 'registry-hagezi-allow-referral',
    name: "HaGeZi's Allowlist Referral",
    url: 'https://adguardteam.github.io/HostlistsRegistry/assets/filter_61.txt',
    category: 'Other',
    enabled: false
  },
  {
    id: '2',
    name: 'AdAway Default Blocklist',
    url: 'https://adguardteam.github.io/HostlistsRegistry/assets/filter_2.txt',
    category: 'Other',
    enabled: true
  }
];

let lastApply = null;
const mockProgress = {
  complete: false,
  inProgress: false,
  completedPhases: []
};

const contentTypes = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml; charset=utf-8'
};

function sendJson(res, status, payload) {
  const body = JSON.stringify(payload, null, 2);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store'
  });
  res.end(body);
}

function collectBody(req) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.setEncoding('utf8');
    req.on('data', chunk => {
      body += chunk;
      if (body.length > 256 * 1024)
        reject(new Error('Request body is too large'));
    });
    req.on('end', () => resolve(body));
    req.on('error', reject);
  });
}

function parsePayload(body) {
  if (!body)
    return {};
  return JSON.parse(body);
}

function delay(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function validatePayload(payload) {
  const errors = [];
  const account = payload.account || {};
  const wifi = payload.wifi || {};
  const vpn = payload.vpn || {};
  const tailscale = payload.tailscale || {};

  if (!account.login || !String(account.login).trim())
    errors.push('SSH login is required.');
  if (String(account.login || '').trim() !== 'root')
    errors.push('This OpenWrt image supports root SSH login only.');
  if (!account.password || String(account.password).length < 8)
    errors.push('SSH password must be at least 8 characters.');
  if (account.password !== account.passwordConfirm)
    errors.push('Password confirmation does not match.');
  if (wifi.enabled) {
    if (!wifi.enable2g && !wifi.enable5g)
      errors.push('Enable at least one Wi-Fi band.');
    if (!String(wifi.ssid || '').trim() || String(wifi.ssid).length > 32)
      errors.push('Wi-Fi network name must be 1 to 32 characters.');
    if (wifi.security !== 'none' && String(wifi.password || '').length < 8)
      errors.push('Wi-Fi password must be at least 8 characters.');
  }
  if (vpn.enabled) {
    const vpnUrl = String(vpn.vlessUrl || '');
    if (!vpnUrl.startsWith('vless://') && !vpnUrl.startsWith('https://'))
      errors.push('A VLESS link or HTTPS subscription link is required when VPN is enabled.');
  }
  if (!Array.isArray(payload.adguard?.selectedFilterIds) || payload.adguard.selectedFilterIds.length === 0)
    errors.push('Select at least one AdGuard blocklist.');
  if (tailscale.enabled) {
    if (!String(tailscale.loginServer || '').trim().startsWith('https://'))
      errors.push('Tailscale or Headscale URL must use HTTPS.');
    if (!String(tailscale.authKey || '').trim())
      errors.push('Tailscale preauth key is required.');
  }

  return errors;
}

function redactedApply(payload) {
  const selected = new Set(payload.adguard?.selectedFilterIds || []);
  return {
    router: {
      lanIp: '10.77.0.1',
      luciUrl: 'http://10.77.0.1/cgi-bin/luci/',
      vpnUrl: 'http://10.77.0.1/cgi-bin/luci/admin/network/vpn',
      adguardUrl: 'http://10.77.0.1:3000/'
    },
    account: {
      login: payload.account?.login || 'root',
      passwordWillBeSet: !!payload.account?.password,
      sshKeyCount: String(payload.account?.authorizedKeys || '')
        .split('\n')
        .filter(line => line.trim()).length
    },
    vpn: {
      enabled: !!payload.vpn?.enabled,
      vlessWillBeStored: !!payload.vpn?.vlessUrl
    },
    adguard: {
      selectedFilters: adguardFilters
        .filter(filter => selected.has(filter.id))
        .map(filter => ({ id: filter.id, name: filter.name, url: filter.url }))
    },
    tailscale: {
      enabled: !!payload.tailscale?.enabled,
      loginServer: payload.tailscale?.enabled ? payload.tailscale.loginServer : '',
      authKeyWillBeUsed: !!payload.tailscale?.authKey
    }
  };
}

function bootstrapPayload() {
  return {
    router: {
      hostname: 'openwrt-fin0',
      lanIp: '10.77.0.1',
      firmware: 'OpenWrt 24.10.5 x86/64',
      luciPath: '/cgi-bin/luci/'
    },
    defaults: {
      accountLogin: 'root',
      wifiEnabled: false,
      wifiSsid: 'OpenWrt',
      wifiCountry: 'US',
      vpnEnabled: true,
      tailscaleEnabled: false,
      tailscaleLoginServer: 'https://headscale.example.com'
    },
    wifi: {
      radios: [
        { device: 'radio0', band: '2g', label: '2.4 GHz' },
        { device: 'radio1', band: '5g', label: '5 GHz' }
      ]
    },
    adguard: {
      source: 'mocked AdGuard Hostlists Registry plus openwrt-fin0 installed filters',
      filters: adguardFilters
    },
    lastApply
  };
}

async function handleApi(req, res, pathname) {
  if (req.method === 'GET' && pathname === '/api/status') {
    sendJson(res, 200, { ok: true, ...mockProgress });
    return;
  }

  if (req.method === 'GET' && pathname === '/api/bootstrap') {
    sendJson(res, 200, { ok: true, data: bootstrapPayload() });
    return;
  }

  if (req.method === 'POST' && pathname === '/api/apply') {
    try {
      const payload = parsePayload(await collectBody(req));
      const errors = validatePayload(payload);
      if (errors.length) {
        sendJson(res, 422, { ok: false, errors });
        return;
      }
      if (applyDelayMs > 0)
        await delay(applyDelayMs);

      lastApply = {
        id: `mock-${Date.now()}`,
        appliedAt: new Date().toISOString(),
        preview: redactedApply(payload),
        phases: [
          'Set root account and SSH keys',
          'Configure LAN on 10.77.0.1',
          payload.wifi?.enabled ? 'Configure Wi-Fi access points' : 'Leave Wi-Fi disabled',
          'Write AdGuardHome filters',
          payload.vpn?.enabled ? 'Render and test Xray config' : 'Disable Xray services',
          payload.tailscale?.enabled ? 'Run tailscale up' : 'Leave Tailscale logged out',
          'Mark first-boot setup complete'
        ]
      };
      mockProgress.complete = true;
      mockProgress.inProgress = false;
      mockProgress.completedPhases = ['account', 'network', 'wifi', 'adguard', 'vpn', 'tailscale'];
      sendJson(res, 200, { ok: true, data: lastApply });
    }
    catch (error) {
      sendJson(res, 400, { ok: false, errors: [error.message] });
    }
    return;
  }

  sendJson(res, 404, { ok: false, errors: ['Unknown API endpoint'] });
}

async function serveStatic(req, res, pathname) {
  const requested = pathname === '/' ? '/index.html' : pathname;
  const safePath = normalize(decodeURIComponent(requested)).replace(/^(\.\.[/\\])+/, '');
  const filePath = join(webDir, safePath);

  if (!filePath.startsWith(webDir) || !existsSync(filePath)) {
    res.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' });
    res.end('Not found');
    return;
  }

  const data = await readFile(filePath);
  const type = contentTypes[extname(filePath)] || 'application/octet-stream';
  res.writeHead(200, {
    'content-type': type,
    'cache-control': 'no-store'
  });
  res.end(data);
}

createServer(async (req, res) => {
  try {
    const url = new URL(req.url || '/', `http://${req.headers.host || '127.0.0.1'}`);
    if (url.pathname.startsWith('/api/')) {
      await handleApi(req, res, url.pathname);
      return;
    }
    await serveStatic(req, res, url.pathname);
  }
  catch (error) {
    sendJson(res, 500, { ok: false, errors: [error.message] });
  }
}).listen(port, '127.0.0.1', () => {
  console.log(`OpenWrt first-boot wizard preview: http://127.0.0.1:${port}`);
});
