import axios from 'axios';

export const DEFAULT_SOURCES = [
    'https://raw.githubusercontent.com/Ruddernation-Designs/Adobe-URL-Block-List/master/hosts',
    'https://raw.githubusercontent.com/ignaciocastro/a-dove-is-dumb/main/list.txt',
];

const isValidDomain = (value: string): boolean => {
    // Basic domain validation: allows subdomains and hyphens, rejects IPs and localhost-style entries.
    if (!value || value === 'localhost') {
        return false;
    }
    if (/^\d+\.\d+\.\d+\.\d+$/.test(value)) {
        return false;
    }
    if (/^::/.test(value)) {
        return false;
    }
        return /^[a-z0-9.-]+$/i.test(value);
};

const normalizeDomain = (value: string): string | null => {
    const trimmed = value.trim().replace(/^\.+/, '').toLowerCase();
    return isValidDomain(trimmed) ? trimmed : null;
};

const collectDomains = (content: string, domains: Set<string>) => {
    for (const rawLine of content.split(/\r?\n/)) {
        const line = rawLine.trim();
        if (!line || line.startsWith('#')) {
            continue;
        }

        const withoutInlineComment = line.split('#')[0]?.trim();
        if (!withoutInlineComment) {
            continue;
        }

        const parts = withoutInlineComment.split(/\s+/).filter(Boolean);
        if (!parts.length) {
            continue;
        }

        // Hosts files often use "0.0.0.0 domain" or "127.0.0.1 domain" formats.
        const candidate = parts.length === 1 ? parts[0] : parts[parts.length - 1];
        const normalized = normalizeDomain(candidate);
        if (normalized) {
            domains.add(normalized);
        }
    }
};

export const fetchHosts = async (sources: string | string[] = DEFAULT_SOURCES): Promise<string[]> => {
    const sourceList = Array.isArray(sources) ? sources : [sources];
    const domains = new Set<string>();

    for (const sourceUrl of sourceList) {
        try {
            const response = await axios.get<string>(sourceUrl, { responseType: 'text' });
            collectDomains(response.data, domains);
        } catch (error) {
            console.error(`Error fetching hosts from ${sourceUrl}:`, error);
        }
    }

    return Array.from(domains).sort((a, b) => a.localeCompare(b));
};
