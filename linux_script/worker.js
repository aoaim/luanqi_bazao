export default {
  async fetch(request) {
    const url = new URL(request.url);
    const path = url.pathname;
    const domain = url.hostname;

    const textHeaders = {
      'Content-Type': 'text/plain; charset=utf-8',
      'Cache-Control': 'no-cache, no-store, must-revalidate',
      'Pragma': 'no-cache',
      'Expires': '0',
    };

    const routes = {
      '/reinstall': 'https://raw.githubusercontent.com/aoaim/luanqi_bazao/refs/heads/main/linux_script/reinstall_os.sh',
      '/debian': 'https://raw.githubusercontent.com/aoaim/luanqi_bazao/refs/heads/main/linux_script/debian_init.sh',
      '/proxy': 'https://raw.githubusercontent.com/aoaim/luanqi_bazao/refs/heads/main/linux_script/install_snell.sh',
      '/wireguard': 'https://raw.githubusercontent.com/aoaim/luanqi_bazao/refs/heads/main/linux_script/install_wireguard.sh',
      '/realm': 'https://raw.githubusercontent.com/aoaim/luanqi_bazao/refs/heads/main/linux_script/install_realm.sh',
      '/zram': 'https://raw.githubusercontent.com/aoaim/luanqi_bazao/refs/heads/main/linux_script/zram_manage.sh',
      '/bench': 'https://raw.githubusercontent.com/masonr/yet-another-bench-script/refs/heads/master/yabs.sh',
      '/check': 'https://raw.githubusercontent.com/aoaim/luanqi_bazao/refs/heads/main/linux_script/check.sh',
    };

    const menuScript = `#!/usr/bin/env bash
set -e

DOMAIN="https://${domain}"

print_menu() {
  cat <<EOF

mmm's Script Hub
=================

Choose a script:
  1) reinstall   - reinstall OS (Debian/Ubuntu/Rocky/Alma/Alpine)
  2) debian      - Debian 13+ init (tools, timezone, kernel tuning)
  3) proxy       - install & manage Snell (obfs/Shadow-TLS/ShadowSocks)
  4) wireguard   - install & manage WireGuard server
  5) realm       - install & manage realm relay
  6) zram        - manage ZRAM swap
  7) bench       - run YABS benchmark
  8) check       - region restriction check (streaming/AI)
  q) quit

EOF
}

run_script() {
  local cmd="$1"
  echo
  echo "Running: $cmd"
  echo

  if [ ! -r /dev/tty ]; then
    echo "Interactive input is not available." >&2
    exit 1
  fi

  local tmp
  tmp="$(mktemp)" || {
    echo "Failed to create temporary file." >&2
    exit 1
  }

  trap 'rm -f "$tmp"' RETURN

  curl -fsSL "$DOMAIN/$cmd" -o "$tmp" || {
    echo "Download failed: $cmd" >&2
    exit 1
  }

  chmod +x "$tmp"
  bash "$tmp" < /dev/tty
}

normalize_choice() {
  case "$1" in
    1|reinstall) echo "reinstall" ;;
    2|debian) echo "debian" ;;
    3|proxy) echo "proxy" ;;
    4|wireguard) echo "wireguard" ;;
    5|realm) echo "realm" ;;
    6|zram) echo "zram" ;;
    7|bench) echo "bench" ;;
    8|check) echo "check" ;;
    q|Q|quit|exit) echo "quit" ;;
    *) echo "" ;;
  esac
}

if [ "$#" -gt 0 ]; then
  choice="$(normalize_choice "$1")"
  case "$choice" in
    quit)
      echo "Bye."
      exit 0
      ;;
    "")
      echo "Invalid argument: $1" >&2
      exit 1
      ;;
    *)
      run_script "$choice"
      exit $?
      ;;
  esac
fi

print_menu

if [ ! -r /dev/tty ]; then
  echo "Interactive input is not available." >&2
  echo "Please run this command in a terminal." >&2
  exit 1
fi

printf "Enter choice: " > /dev/tty
if ! read -r raw_choice < /dev/tty; then
  echo
  echo "No input received. Bye." >&2
  exit 1
fi
choice="$(normalize_choice "$raw_choice")"

case "$choice" in
  reinstall|debian|proxy|wireguard|realm|zram|bench|check)
    run_script "$choice"
    ;;
  quit)
    echo "Bye."
    exit 0
    ;;
  *)
    echo "Invalid choice." >&2
    exit 1
    ;;
esac
`;

    const browserText = `Terminal use only.

Run:

curl -fsSL https://${domain} | bash
`;

    const userAgent = request.headers.get('user-agent') || '';
    const accept = request.headers.get('accept') || '';
    const secFetchDest = request.headers.get('sec-fetch-dest') || '';

    const isBrowserRequest =
      secFetchDest === 'document' ||
      accept.includes('text/html') ||
      /mozilla|chrome|safari|firefox|edge/i.test(userAgent);

    if (path === '/') {
      if (isBrowserRequest) {
        return new Response(browserText, {
          status: 200,
          headers: textHeaders,
        });
      }

      return new Response(menuScript, {
        status: 200,
        headers: textHeaders,
      });
    }

    const target = routes[path];

    if (!target) {
      return new Response(`404: Unknown command '${path}'.\n`, {
        status: 404,
        headers: textHeaders,
      });
    }

    try {
      const res = await fetch(target, {
        cf: {
          cacheTtl: 0,
          cacheEverything: false,
        },
      });

      if (!res.ok) {
        return new Response(
          `Upstream fetch failed: ${res.status} ${res.statusText}\n`,
          {
            status: res.status,
            headers: textHeaders,
          }
        );
      }

      return new Response(res.body, {
        status: 200,
        headers: textHeaders,
      });
    } catch (err) {
      return new Response(
        `Upstream fetch error: ${err && err.message ? err.message : 'unknown error'}\n`,
        {
          status: 502,
          headers: textHeaders,
        }
      );
    }
  },
};
