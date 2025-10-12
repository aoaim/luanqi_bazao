# AdGuard to Surge

- Converts AdGuard block lists into Surge domain-set files (workflow adapted from `geekdada/surge-list`).
- GitHub Actions workflow: `.github/workflows/adguard2surge.yml` (cron `0 0 */2 * *`, plus manual dispatch).
- Output files: `proxy_filter/surge/tracking-protection-filter.txt`, `chinese-filter.txt`, `base-filter.txt`, `dns-filter.txt`.
- Source URLs:
	- Tracking Protection: https://raw.githubusercontent.com/AdguardTeam/FiltersRegistry/master/filters/filter_3_Spyware/filter.txt
	- Chinese: https://raw.githubusercontent.com/AdguardTeam/FiltersRegistry/master/filters/filter_224_Chinese/filter.txt
	- Base: https://raw.githubusercontent.com/AdguardTeam/FiltersRegistry/master/filters/filter_2_Base/filter.txt
	- DNS: https://raw.githubusercontent.com/AdguardTeam/FiltersRegistry/master/filters/filter_15_DnsFilter/filter.txt

## Manual Run

```bash
cd rule_generator/adguard2surge
npm install
npm run gen-domain-set
```

Commit the updated files under `proxy_filter/surge/` if the contents change.
