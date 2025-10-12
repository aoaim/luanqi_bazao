# Adobe Block Host Surge Generator

This package converts Adobe host lists from an upstream GitHub source into Surge-compatible rules. It lives inside the `rule_generator` workspace so that we can add other converters alongside it.

## Features

- Fetches host entries from a GitHub URL.
- Converts the fetched host entries into Surge rule format.
- Automatically updates the Surge rules file with new entries.

## Project Structure

```
rule_generator/adobe_block_host_surge
├── .github
│   └── workflows
│       └── convert.yml
├── src
│   ├── index.ts
│   ├── services
│   │   └── surgeConverter.ts
│   └── utils
│       └── fetchHosts.ts
├── scripts
│   └── updateRules.ts
├── package.json
├── tsconfig.json
└── README.md
```

## Installation

1. Install the dependencies:
   ```
   npm install
   ```

## Usage

To run the conversion process and update the Surge rules, execute the following command:
```
npm run update:adobe
```

This will fetch the host entries from the specified GitHub URL, convert them into Surge rules, and write the result to `proxy_filter/adobe.list` at the repository root.

## GitHub Actions

The project includes a GitHub Actions workflow defined in `.github/workflows/convert.yml` that runs nightly (and on manual dispatch) to refresh `proxy_filter/adobe.list` and auto-commit the result.

## Contributing

Contributions are welcome! Please feel free to submit a pull request or open an issue for any suggestions or improvements.

## License

This project is licensed under the MIT License.