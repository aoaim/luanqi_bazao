# AdGuard to Sing-Box

Converts AdGuard block lists and other filter lists into Sing-Box `.srs` rule sets.

## Workflow

- **Workflow File**: `.github/workflows/adguard2singbox.yml`
- **Schedule**: Every 2 days at 00:00 UTC (`0 0 */2 * *`), plus manual dispatch.

## Output Files

Generated rules are saved in `proxy_filter/sing-box/`.

| Rule Name | Output File | Source |
| :--- | :--- | :--- |
| **Adguard DNS Filter** | `adguard-dns-filter.srs` | [Source](https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt) |
| **Adguard Base Filter** | `adguard-base-filter.srs` | [Source](https://raw.githubusercontent.com/AdguardTeam/FiltersRegistry/master/filters/filter_2_Base/filter.txt) |
| **Adguard Chinese Filter** | `adguard-chinese-filter.srs` | [Source](https://raw.githubusercontent.com/AdguardTeam/FiltersRegistry/master/filters/filter_224_Chinese/filter.txt) |
| **Adguard Tracking Protection Filter** | `adguard-tracking-protection-filter.srs` | [Source](https://raw.githubusercontent.com/AdguardTeam/FiltersRegistry/master/filters/filter_3_Spyware/filter.txt) |
| **Hagezi Pro Filter** | `hagezi-pro-filter.srs` | [Source](https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/pro.txt) |
| **Hagezi Anti-Piracy Filter** | `hagezi-anti-piracy-filter.srs` | [Source](https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/anti.piracy.txt) |
| **anti-AD** | `anti-ad.srs` | [Source](https://anti-ad.net/adguard.txt) |

## Manual Run

1. Download the current sing-box binary (matching the one in the workflow, e.g., v1.12.9).
2. Download the source lists (urls listed above) into a directory.
3. Convert each file using:
   ```bash
   sing-box rule-set convert <input.txt> --output <output.srs> --type adguard
   ```
4. Move the `.srs` files to `proxy_filter/sing-box/`.
