import path from 'path';
import { promises as fs } from 'fs';
import { fetchHosts, DEFAULT_SOURCE } from './utils/fetchHosts';
import { convertToSurgeRules } from './services/surgeConverter';

const OUTPUT_PATH = path.resolve(__dirname, '../../../proxy_filter/surge/adobe.list');

const buildFileContent = (rules: string[], source: string): string => {
    const header = [
        '## Adobe domains converted for Surge',
        `## Source: ${source}`,
        `## Updated: ${new Date().toISOString()}`,
        '',
    ];

    return `${header.join('\n')}${rules.join('\n')}${rules.length ? '\n' : ''}`;
};

export const generateAdobeSurgeList = async (
    outputPath: string = OUTPUT_PATH,
    sourceUrl: string = DEFAULT_SOURCE,
): Promise<void> => {
    const hosts = await fetchHosts(sourceUrl);
    if (!hosts.length) {
        throw new Error('No hosts retrieved from upstream source.');
    }

    const rules = convertToSurgeRules(hosts);
    const fileContent = buildFileContent(rules, sourceUrl);

    await fs.mkdir(path.dirname(outputPath), { recursive: true });
    await fs.writeFile(outputPath, fileContent, 'utf8');

    const relativePath = path.relative(process.cwd(), outputPath) || outputPath;
    console.log(`Generated ${rules.length} Surge rules at ${relativePath}`);
};

if (require.main === module) {
    generateAdobeSurgeList().catch((error) => {
        console.error('Error generating Surge rules:', error);
        process.exitCode = 1;
    });
}