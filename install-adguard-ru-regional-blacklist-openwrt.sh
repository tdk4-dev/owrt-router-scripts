#!/bin/sh
set -eu

NAME=${NAME:-ru-regional-blacklist}
WEB_ROOT=${WEB_ROOT:-/www}
WEB_DIR=${WEB_ROOT}/adguard
LIST_PATH=${LIST_PATH:-$WEB_DIR/$NAME.txt}
FILTER_URL=${FILTER_URL:-http://127.0.0.1/adguard/$NAME.txt}
CONFIG=${CONFIG:-}
WORK_DIR=${WORK_DIR:-}
AGH_BIN=${AGH_BIN:-$(command -v AdGuardHome 2>/dev/null || echo /usr/bin/AdGuardHome)}
SERVICE=${SERVICE:-/etc/init.d/adguardhome}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

warn() {
  echo "WARN: $*" >&2
}

usage() {
  cat <<EOF
Usage: sh $0

Installs the RU regional ad DNS blocklist into AdGuard Home on an OpenWrt router.

Optional environment overrides:
  CONFIG=/path/to/AdGuardHome.yaml
  WORK_DIR=/path/to/adguard/workdir
  WEB_ROOT=/www
  FILTER_URL=http://127.0.0.1/adguard/ru-regional-blacklist.txt
  AGH_BIN=/usr/bin/AdGuardHome
  SERVICE=/etc/init.d/adguardhome
EOF
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

[ "$(id -u)" = "0" ] || die "Run this on the router as root."

if [ -z "$CONFIG" ]; then
  if [ -f /etc/adguardhome.yaml ]; then
    CONFIG=/etc/adguardhome.yaml
  else
    CONFIG=$(ps w | awk '
      /[A]dGuardHome/ {
        for (i = 1; i <= NF; i++) {
          if (($i == "-c" || $i == "--config") && (i + 1) <= NF) {
            print $(i + 1)
            exit
          }
          if ($i ~ /^--config=/) {
            sub(/^--config=/, "", $i)
            print $i
            exit
          }
        }
      }
    ')
  fi
fi

if [ -z "$WORK_DIR" ]; then
  WORK_DIR=$(ps w | awk '
    /[A]dGuardHome/ {
      for (i = 1; i <= NF; i++) {
        if (($i == "-w" || $i == "--work-dir") && (i + 1) <= NF) {
          print $(i + 1)
          exit
        }
        if ($i ~ /^--work-dir=/) {
          sub(/^--work-dir=/, "", $i)
          print $i
          exit
        }
      }
    }
  ')
  WORK_DIR=${WORK_DIR:-/var/lib/adguardhome}
fi

[ -f "$CONFIG" ] || die "AdGuard Home config not found. Set CONFIG=/path/to/AdGuardHome.yaml."
[ -x "$AGH_BIN" ] || die "AdGuardHome binary not found. Set AGH_BIN=/path/to/AdGuardHome."
grep -q '^filters:' "$CONFIG" || die "Config does not contain a filters: section."

mkdir -p "$WEB_DIR"

cat > "$LIST_PATH" <<'RULES'
! AdGuard Home custom DNS overlay: RU/CIS regional advertising
! Generated: 2026-06-13
! Scope: DNS-safe hostname rules only. Add under Filters -> Custom filtering rules,
! or host this file and add it as a DNS blocklist.
!
! Notes:
! - This intentionally does NOT block shared Yandex/Kinopoisk asset hosts such as
!   yandex.ru, yastatic.net, avatars.mds.yandex.net, cdn.yandex.net, strm.yandex.ru,
!   kinopoisk.ru, or hd.kinopoisk.ru. Blocking those at DNS level breaks normal pages.
! - Kinopoisk top banners may still need browser cosmetic filtering because many
!   Adfox/Yandex ad assets are served by shared first-party paths, not ad-only hosts.
! - Rules are deliberately bare AdGuard Home hostname rules. Unsupported browser
!   modifiers such as $third-party are not used.

! Yandex / Adfox / Yandex Ads
||an.yandex.*^
||yabs.yandex.*^
||bs.yandex.*^
||awaps.yandex.net^
||kiks.yandex.*^
||adsdk.yandex.*^
||adfox.yandex.*^
||ads.adfox.yandex.*^
||ads6.adfox.yandex.*^
||matchid.adfox.yandex.*^
||yandexadexchange.net^
||adfox.ru^
||adfox.net^
||ads.adfox.ru^
||ads6.adfox.ru^
||banners.adfox.ru^
||banners.adfox.net^
||content.adfox.ru^

! VK / Mail.ru advertising, recommendation, and counters
||ad.mail.ru^
||ads.mail.ru^
||rs.mail.ru^
||top-fwz1.mail.ru^
||relap.mail.ru^
||media-advcycle.imgsmail.ru^
||target.my.com^
||targetmail.ru^
||vk-ads.ru^
||ads.vk.com^
||ads.vk.ru^
||ads-api.vk.com^
||ads-api.vk.ru^
||prod.html5-ads.vk-apps.com^

! Rambler / Top100 / regional media ad pipes
||ad2.rambler.ru^
||ad3.rambler.ru^
||ads.rambler.ru^
||ssp.rambler.ru^
||rcmjs.rambler.ru^
||redsquare.rambler.ru^
||counter.rambler.ru^
||top100.rambler.ru^

! Major RU/CIS adservers and programmatic exchanges
||adriver.ru^
||ad.adriver.ru^
||content.adriver.ru^
||ssp.adriver.ru^
||mh.adriver.ru^
||am15.net^
||begun.ru^
||video.begun.ru^
||directadvert.ru^
||adlook.tech^
||adpartner.pro^
||bidmatic.io^
||bidvol.com^
||ssp.bidvol.com^
||between.digital^
||betweenx.com^
||dm.hybrid.ai^
||hybrid.ai^
||getintent.com^
||otm-r.com^
||programmatica.com^
||roxot-panel.com^
||soloway.ru^
||sape.ru^
||segmento.ru^

! Native/teaser networks common on Russian-language sites
||24smi.net^
||24smi.org^
||jsn.24smi.net^
||jsn.24smi.org^
||data.24smi.net^
||smi.today^
||smi24.kz^
||smi2.ru^
||smi2.net^
||smigid.ru^
||smilered.com^
||sminewsnet.ru^
||neosmi.ru^
||data.neosmi.ru^
||tiz.neosmi.ru^
||mediametrics.ru^
||partner.mediametrics.ru^
||lentainform.com^
||marketgid.com^
||mgid.com^
||jsc.mgid.com^
||wsp.marketgid.com^
||dt00.net^
||dt07.net^
||kadam.net^
||kadam.ru^
||adwile.com^
||buzzoola.com^
||bodyclick.net^
||gnezdo.ru^
||redtram.com^
||g4p.redtram.com^
||ladycash.ru^
||livesmi.com^
||luxup.ru^
||luxupadva.com^
||luxupcdna.com^
||mixadvert.com^
||teasernet.com^
||teasernet.ru^
||teaser.cc^
||teaser-goods.ru^
||teasereach.com^
||teasergold.ru^
||teaserleads.com^
||teasermall.com^
||teasermedia.net^
||teasers.ru^
||teaser.meta.ua^
||autoteaser.ru^
||gameteaser.ru^
||globalteaser.com^
||globalteaser.ru^
||phpteaser.ru^
||svk-native.ru^
||trafmag.com^
||traffic-media.co^

! Video/VAST/player ad delivery seen on RU/CIS streaming and media sites
||adplay.ru^
||adstreamer.ru^
||flyroll.ru^
||videonow.ru^
||video.videonow.ru^
||videoprodavec.ru^
||doprodavec.ru^
||advast.sibnet.ru^
||rtb.wedeo.ru^
||vast.playmatic.video^
||partner.pladform.ru^
||daast.digitalbox.ru^

! Regional first-party ad subdomains from Russian-language filters
||ad.cbonds.info^
||ad.iplayer.org^
||ad.megapeer.ru^
||ad.tehno-rating.ru^
||ad.topwar.ru^
||ad.velomania.ru^
||adbn.masterinvest.info^
||adshow.sc2tv.ru^
||ads.211.ru^
||ads.dfiles.ru^
||ads.interfax.ru^
||ads.livetvcdn.net^
||ads.kingads.digital^
||ads.people-group.net^
||ads.digitalcaramel.com^
||adsparking.inzhener-info.ru^
||banner.kaktus.media^
||banner.profile.ru^
||banner.zol.ru^
||banners.haqqin.az^
||banners.prikol.ru^
||banners.tapclap.com^
||banshop.gruntovik.ru^
||b.1istochnik.ru^
||b.kakoysegodnyaprazdnik.ru^
||b.povarenok.ru^
||b13.penzainform.ru^
||bn.take-profit.org^
||bs.orsk.ru^
||da.rosrabota.ru^
||e.60sk.ru^
||ff.astv.ru^
||flowers.moex.com^
||honey.briefly.ru^
||ncs.eadaily.com^
||o.60sk.ru^
||pr.ikovrov.ru^
||pr.rusmed.ru^
||r1.ati.su^
||r.z2.fm^
||r.z3.fm^
||rtb.wedeo.ru^
||t.sur.new.gorodkirov.ru^
||userdata.ati.su^

! Optional test-only Kinopoisk/Yandex CDN candidates:
! Do not enable these globally unless you accept breakage on Yandex/Kinopoisk.
! ||avatars.mds.yandex.net^
! ||cdn.yandex.net^
! ||strm.yandex.ru^
! ||yastatic.net^
RULES

chmod 0644 "$LIST_PATH"

http_ok=0
if command -v wget >/dev/null 2>&1; then
  if wget -qO- "$FILTER_URL" 2>/dev/null | grep -q 'AdGuard Home custom DNS overlay'; then
    http_ok=1
  fi
elif command -v curl >/dev/null 2>&1; then
  if curl -fsSL --max-time 5 "$FILTER_URL" 2>/dev/null | grep -q 'AdGuard Home custom DNS overlay'; then
    http_ok=1
  fi
else
  warn "Neither wget nor curl is available; skipping URL reachability check."
  http_ok=1
fi

if [ "$http_ok" != "1" ]; then
  die "The blocklist URL is not reachable from this router: $FILTER_URL. Ensure OpenWrt uhttpd is running on port 80, or set FILTER_URL to a reachable raw text URL."
fi

TMP=/tmp/adguardhome.yaml.$NAME.$$
BACKUP=
trap 'rm -f "$TMP"' EXIT

if grep -q "url: $FILTER_URL" "$CONFIG"; then
  echo "Filter URL already exists in $CONFIG; refreshed $LIST_PATH."
else
  BACKUP=$CONFIG.bak.$NAME.$(date +%Y%m%d-%H%M%S)
  cp "$CONFIG" "$BACKUP"
  MAXID=$(awk '/^[[:space:]]+id: [0-9]+$/ { if ($2 > m) m = $2 } END { if (m == 0) print 1779019550; else print m + 1 }' "$CONFIG")

  awk -v url="$FILTER_URL" -v name="$NAME" -v id="$MAXID" '
    /^filters:[[:space:]]*\[\][[:space:]]*$/ && !inserted {
      print "filters:"
      print "  - enabled: true"
      print "    url: " url
      print "    name: " name
      print "    id: " id
      inserted = 1
      next
    }
    /^(whitelist_filters:|user_rules:|dhcp:)/ && !inserted {
      print "  - enabled: true"
      print "    url: " url
      print "    name: " name
      print "    id: " id
      inserted = 1
    }
    { print }
    END { if (!inserted) exit 2 }
  ' "$CONFIG" > "$TMP"

  "$AGH_BIN" -c "$TMP" -w "$WORK_DIR" --check-config
  mv "$TMP" "$CONFIG"
fi

if [ -x "$SERVICE" ]; then
  "$SERVICE" restart
elif "$AGH_BIN" -s reload >/dev/null 2>&1; then
  :
elif "$AGH_BIN" -s restart >/dev/null 2>&1; then
  :
else
  warn "Could not restart AdGuard Home automatically. Restart it manually to load the new filter."
fi

echo
echo "Installed $NAME."
echo "Blocklist file: $LIST_PATH"
echo "AdGuard Home URL: $FILTER_URL"
[ -n "$BACKUP" ] && echo "Config backup: $BACKUP"
echo "Open AdGuard Home -> Filters -> DNS blocklists and refresh the page."
