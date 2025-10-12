import { generateAdobeSurgeList } from '../src/index';

generateAdobeSurgeList().catch((error) => {
    console.error('Error updating Surge rules:', error);
    process.exitCode = 1;
});