# AdGuard to Surge

Converts AdGuard block lists into Surge domain-set files.

## Workflow

- **Workflow File**: `.github/workflows/adguard2surge.yml`
- **Schedule**: Every 2 days at 00:00 UTC (`0 0 */2 * *`), plus manual dispatch.

## Output Files

Generated rules are saved in `proxy_filter/surge/`.

| Rule Name | Output File | Source |
| :--- | :--- | :--- |
| **Adguard Tracking Protection Filter** | `adguard-tracking-protection-filter.txt` | [Source](https://raw.githubusercontent.com/AdguardTeam/FiltersRegistry/master/filters/filter_3_Spyware/filter.txt) |
| **Adguard Chinese Filter** | `adguard-chinese-filter.txt` | [Source](https://raw.githubusercontent.com/AdguardTeam/FiltersRegistry/master/filters/filter_224_Chinese/filter.txt) |
| **Adguard Base Filter** | `adguard-base-filter.txt` | [Source](https://raw.githubusercontent.com/AdguardTeam/FiltersRegistry/master/filters/filter_2_Base/filter.txt) |
| **Adguard DNS Filter** | `adguard-dns-filter.txt` | [Source](https://raw.githubusercontent.com/AdguardTeam/FiltersRegistry/master/filters/filter_15_DnsFilter/filter.txt) |
| **Hagezi Pro Filter** | `hagezi-pro-filter.txt` | [Source](https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/pro.txt) |
| **Hagezi Anti-Piracy Filter** | `hagezi-anti-piracy-filter.txt` | [Source](https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/anti.piracy.txt) |

## Manual Run

```bash
cd rule_generator/adguard2surge
npm install
npm run gen-domain-set
```

Commit the updated files under `proxy_filter/surge/` if the contents change.
