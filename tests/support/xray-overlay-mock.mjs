#!/usr/bin/env node
import fs from 'node:fs';

const fail = message => {
	process.stdout.write(`${JSON.stringify({ ok: false, error: message })}\n`);
	process.exit(1);
};
const readJson = file => {
	try {
		return JSON.parse(fs.readFileSync(file, 'utf8'));
	}
	catch {
		fail('Xray configuration is not valid JSON');
	}
};
const eligibleRule = (rule, key) => rule && rule.type === 'field' &&
	rule.outboundTag === 'direct' && Array.isArray(rule[key]) &&
	rule[key].every(value => typeof value === 'string') &&
	Object.keys(rule).every(name => ['type', 'outboundTag', key].includes(name));
const inspect = config => {
	const rules = config?.routing?.rules;
	if (!Array.isArray(rules))
		fail('Xray routing.rules is missing or is not an array');
	const domains = [];
	const ips = [];
	rules.forEach((rule, index) => {
		if (eligibleRule(rule, 'domain')) domains.push(index);
		if (eligibleRule(rule, 'ip')) ips.push(index);
	});
	if (domains.length !== 1)
		fail(`expected exactly one isolated direct domain array, found ${domains.length}`);
	if (ips.length !== 1)
		fail(`expected exactly one isolated direct IP array, found ${ips.length}`);
	return {
		ok: true,
		domain_rule_index: domains[0],
		ip_rule_index: ips[0],
		domain_count: rules[domains[0]].domain.length,
		ip_count: rules[ips[0]].ip.length,
		warnings: config.routing.domainStrategy === 'AsIs'
			? ['routing.domainStrategy AsIs will be preserved'] : []
	};
};
const readList = file => [...new Set(fs.readFileSync(file, 'utf8').split(/\r?\n/)
	.map(value => value.trim()).filter(value => value && !value.startsWith('#')))];
const writeJson = value => process.stdout.write(`${JSON.stringify(value)}\n`);

const [, , _overlaySource, command, configPath, ...args] = process.argv;
if (!command || !configPath)
	fail('usage: xray-overlay.uc inspect|extract|patch CONFIG ...');
const source = readJson(configPath);
const details = inspect(source);

if (command === 'inspect') {
	writeJson(details);
	process.exit(0);
}
const domainIndex = Number(args[0]);
const ipIndex = Number(args[1]);
if (domainIndex !== details.domain_rule_index || ipIndex !== details.ip_rule_index)
	fail('adopted selectors no longer identify the unique managed arrays');
if (command === 'extract') {
	fs.writeFileSync(args[2], `${source.routing.rules[domainIndex].domain.join('\n')}\n`);
	fs.writeFileSync(args[3], `${source.routing.rules[ipIndex].ip.join('\n')}\n`);
	writeJson(details);
	process.exit(0);
}
if (!['patch', 'patch-profile'].includes(command))
	fail('unknown structural overlay command');

const candidate = structuredClone(source);
candidate.routing.rules[domainIndex].domain = readList(args[2]);
candidate.routing.rules[ipIndex].ip = readList(args[3]);
const output = args[4];
let profileUpdated = false;
if (command === 'patch-profile') {
	const profile = readJson(args[5]);
	const matches = candidate.outbounds.map((outbound, index) => ({ outbound, index }))
		.filter(({ outbound }) => outbound?.tag === 'proxy' && outbound.protocol === 'vless');
	if (matches.length !== 1)
		fail(`expected exactly one proxy VLESS outbound, found ${matches.length}`);
	const outbound = matches[0].outbound;
	const server = outbound.settings?.vnext?.[0];
	const user = server?.users?.[0];
	const reality = outbound.streamSettings?.realitySettings;
	if (!server || !user || !reality || outbound.streamSettings.network !== 'tcp' ||
		outbound.streamSettings.security !== 'reality')
		fail('proxy VLESS outbound is outside the supported single-server Reality TCP layout');
	const endpoint = `${profile.old_vps_ip}/32`;
	const endpointMatches = [];
	candidate.routing.rules.forEach((rule, ruleIndex) => {
		if (ruleIndex === ipIndex || rule?.outboundTag !== 'direct' || !Array.isArray(rule.ip)) return;
		rule.ip.forEach((value, itemIndex) => {
			if (value === endpoint) endpointMatches.push([ruleIndex, itemIndex]);
		});
	});
	if (endpointMatches.length !== 1)
		fail(`expected exactly one isolated current endpoint bypass, found ${endpointMatches.length}`);
	server.address = profile.address;
	server.port = profile.port;
	user.id = profile.uuid;
	user.encryption = 'none';
	if (profile.flow) user.flow = profile.flow;
	else delete user.flow;
	outbound.streamSettings.network = 'tcp';
	outbound.streamSettings.security = 'reality';
	Object.assign(reality, {
		serverName: profile.server_name,
		fingerprint: profile.fingerprint,
		publicKey: profile.public_key,
		shortId: profile.short_id,
		spiderX: profile.spider_x
	});
	const [ruleIndex, itemIndex] = endpointMatches[0];
	candidate.routing.rules[ruleIndex].ip[itemIndex] = `${profile.new_vps_ip}/32`;
	profileUpdated = true;
}
fs.writeFileSync(output, `${JSON.stringify(candidate)}\n`);
writeJson({
	ok: true,
	non_managed_semantics_unchanged: true,
	profile_updated: profileUpdated,
	domain_rule_index: domainIndex,
	ip_rule_index: ipIndex,
	domain_count: candidate.routing.rules[domainIndex].domain.length,
	ip_count: candidate.routing.rules[ipIndex].ip.length
});
