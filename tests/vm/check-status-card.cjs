#!/usr/bin/env node
'use strict';

const { chromium } = require('playwright');

(async () => {
  const url = process.argv[2];
  if (!url) throw new Error('status overview URL is required');
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();
  await page.goto(url, { waitUntil: 'networkidle', timeout: 60000 });
  const user = page.locator('input[name="luci_username"]');
  if (await user.count() === 1) {
    await user.fill('root');
    const password = page.locator('input[name="luci_password"]');
    if (await password.count() !== 1) throw new Error('LuCI password control is missing');
    await password.fill('');
    const login = page.locator('button[type="submit"]');
    if (await login.count() !== 1) throw new Error('LuCI login control is ambiguous');
    await Promise.all([page.waitForLoadState('networkidle'), login.click()]);
  }
  await page.waitForTimeout(1500);
  const cards = page.locator('h2, h3').filter({ hasText: 'VPN service' });
  const count = await cards.count();
  if (count !== 1) throw new Error(`expected exactly one visible VPN service card, found ${count}`);
  console.log(JSON.stringify({ ok: true, visible_vpn_status_cards: count, url: page.url() }));
  await browser.close();
})().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
