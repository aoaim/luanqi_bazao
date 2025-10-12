# Adobe Block Host → Surge

- Pulls the Adobe host block list from `Ruddernation-Designs/Adobe-URL-Block-List`.
- Source URL: https://raw.githubusercontent.com/Ruddernation-Designs/Adobe-URL-Block-List/master/hosts
- Converts entries to Surge `DOMAIN-SUFFIX` rules and writes `proxy_filter/surge/adobe.list`.
- GitHub Actions workflow: `.github/workflows/adobe_surge.yml` (cron `0 0 */2 * *`, plus manual dispatch).
- Minimal TypeScript project with one service (`surgeConverter.ts`) and utilities for fetching hosts.

## Manual Run

```bash
cd rule_generator/adobe_block_host_surge
npm install
npm run update:adobe
```

Commit the updated `proxy_filter/surge/adobe.list` if new domains are pulled.