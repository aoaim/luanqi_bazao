export function convertToSurgeRules(hosts: string[]): string[] {
    return hosts.map(host => `DOMAIN-SUFFIX,${host}`);
}