/**
 * ╔══════════════════════════════════════════════════════════════════════════════╗
 * ║                          PubMed 文献标题翻译 v1.0                            ║
 * ║                         Background Service Worker                            ║
 * ║                   Build by Miao and Claude Sonnet 4.5 with ♥                 ║
 * ╚══════════════════════════════════════════════════════════════════════════════╝
 */

chrome.runtime.onInstalled.addListener(() => {
    console.log('PubMed 文献标题翻译插件已安装');
});

/**
 * 处理来自 content script 的请求
 * 在 background script 中发起请求可以绕过 CORS 限制
 */
chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
    if (request.action === 'makeRequest') {
        handleRequest(request.url, request.options)
            .then(data => sendResponse({ data: data }))
            .catch(error => sendResponse({ error: error.message }));
        return true; // 保持消息通道开启以进行异步响应
    }
});

/**
 * 发起网络请求
 */
async function handleRequest(url, options = {}) {
    try {
        const response = await fetch(url, {
            method: options.method || 'GET',
            headers: options.headers || {},
            body: options.body
        });

        if (!response.ok) {
            throw new Error(`HTTP ${response.status}: ${response.statusText}`);
        }

        const contentType = response.headers.get('content-type');
        if (contentType && contentType.includes('application/json')) {
            return await response.json();
        } else {
            return await response.text();
        }
    } catch (error) {
        console.error('Background request failed:', error);
        throw error;
    }
}
