# AdGuard to Sing-Box

- Converts the AdGuard DNS and Anti-AD lists into Sing-Box `.srs` rule sets (approach inspired by `zacred0rryn/srs-custom`).
- GitHub Actions workflow: `.github/workflows/adguard2singbox.yml` (cron `0 0 */2 * *`, plus manual dispatch).
- Output files: `proxy_filter/sing-box/AdGuardDNSFilter.srs` and `proxy_filter/sing-box/CHN_anti-AD.srs`.
- Source URLs:
	- `AdGuardDNSFilter`: https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt
	- `CHN_anti-AD`: https://anti-ad.net/adguard.txt

## Manual Run

1. Download the current sing-box release used in the workflow and extract the binary.
2. Fetch the source lists into a working directory as `<name>.txt`.
3. Convert each file with `sing-box rule-set convert <file.txt> --output <file.srs> --type adguard`.
4. Copy the resulting `.srs` files into `proxy_filter/sing-box/`.
