if (typeof window.browser === 'undefined' && typeof window.chrome !== 'undefined') {
    window.browser = window.chrome;
}

// 默认配置
const DEFAULT_CONFIG = {
    titleProvider: 'microsoft',
    translateAbstract: false,
    abstractProvider: '',
    google: {},
    microsoft: {},
    deepl: { apiKey: '', useFreeApi: true },
    niutrans: { apiKey: '' },
    openai: { apiKey: '', model: 'gpt-5-mini', temperature: 0.3 },
    gemini: { apiKey: '', model: 'gemini-2.5-flash', temperature: 0.3 },
    openrouter: { apiKey: '', model: 'openai/gpt-5-mini', temperature: 0.3 },
    lmrouter: { apiKey: '', model: 'deepseek/deepseek-v3.2-exp', temperature: 0.3 },
    deepseek: { apiKey: '', model: 'deepseek-chat', temperature: 1.3 },
    siliconflow: { apiKey: '', model: 'deepseek-ai/DeepSeek-V3.2-Exp', temperature: 0.3 },
    maxConcurrent: 2,
    requestDelay: 500,
    targetLanguage: 'zh-CN',
    translationStyle: '简体中文',
    cacheEnabled: true,
    cacheDuration: 7,
    // LLM Prompt 配置
    llmSystemPrompt: 'You are a professional medical and biomedical academic translation assistant. Your task is to translate English academic papers, titles, and abstracts into Simplified Chinese accurately, maintaining academic rigor and professional terminology. Ensure translations are precise, natural, and adhere to Chinese academic writing conventions. Do not add any explanations or extra content beyond the translation itself.',
    llmUserPrompt: 'Translate the following English text into Simplified Chinese:\n\n{text}',
};

// 需要 API Key 的服务商
const API_PROVIDERS = ['deepl', 'niutrans', 'openai', 'gemini', 'openrouter', 'lmrouter', 'deepseek', 'siliconflow'];

// 显示提示消息
function showToast(message, isError = false) {
    const toast = document.getElementById('toast');
    toast.textContent = message;
    toast.className = 'toast show' + (isError ? ' error' : '');
    setTimeout(() => {
        toast.className = 'toast';
    }, 3000);
}

// 加载配置到界面
async function loadConfig() {
    try {
        const result = await browser.storage.sync.get('translatorConfig');
        const config = result.translatorConfig || DEFAULT_CONFIG;

        // 基础设置
        document.getElementById('titleProvider').value = config.titleProvider || 'microsoft';
        document.getElementById('translateAbstract').checked = config.translateAbstract || false;
        document.getElementById('abstractProvider').value = config.abstractProvider || '';

        // API 配置
        API_PROVIDERS.forEach(provider => {
            const providerConfig = config[provider] || DEFAULT_CONFIG[provider];
            
            if (provider === 'deepl') {
                const apiKeyInput = document.getElementById(`${provider}-apiKey`);
                const useFreeApiCheckbox = document.getElementById(`${provider}-useFreeApi`);
                if (apiKeyInput) apiKeyInput.value = providerConfig.apiKey || '';
                if (useFreeApiCheckbox) useFreeApiCheckbox.checked = providerConfig.useFreeApi !== false;
            } else if (provider === 'niutrans') {
                const apiKeyInput = document.getElementById(`${provider}-apiKey`);
                if (apiKeyInput) apiKeyInput.value = providerConfig.apiKey || '';
            } else {
                // 其他大模型服务商
                const apiKeyInput = document.getElementById(`${provider}-apiKey`);
                const modelInput = document.getElementById(`${provider}-model`);
                const temperatureInput = document.getElementById(`${provider}-temperature`);
                if (apiKeyInput) apiKeyInput.value = providerConfig.apiKey || '';
                if (modelInput) modelInput.value = providerConfig.model || '';
                if (temperatureInput) temperatureInput.value = providerConfig.temperature || 0.3;
            }
        });

        // 高级设置
        document.getElementById('maxConcurrent').value = config.maxConcurrent || 2;
        document.getElementById('requestDelay').value = config.requestDelay || 500;
        document.getElementById('cacheEnabled').checked = config.cacheEnabled !== false;
        document.getElementById('cacheDuration').value = config.cacheDuration || 7;
        
        // LLM Prompt 配置
        document.getElementById('llmSystemPrompt').value = config.llmSystemPrompt || DEFAULT_CONFIG.llmSystemPrompt;
        document.getElementById('llmUserPrompt').value = config.llmUserPrompt || DEFAULT_CONFIG.llmUserPrompt;
        
        // 加载缓存统计
        loadCacheStats();
    } catch (error) {
        console.error('加载配置失败：', error);
        showToast('加载配置失败：' + error.message, true);
    }
}

// 加载缓存统计信息
async function loadCacheStats() {
    try {
        const result = await browser.storage.local.get('translationCache');
        const cacheCount = result.translationCache ? Object.keys(result.translationCache).length : 0;
        const statsDiv = document.getElementById('cacheStats');
        statsDiv.textContent = `当前缓存：${cacheCount} 条翻译记录`;
    } catch (error) {
        console.error('加载缓存统计失败：', error);
    }
}

// 保存配置
async function saveConfig() {
    const config = {};

    // 基础设置
    config.titleProvider = document.getElementById('titleProvider').value;
    config.translateAbstract = document.getElementById('translateAbstract').checked;
    config.abstractProvider = document.getElementById('abstractProvider').value;

    // API 配置
    config.google = {};
    config.microsoft = {};

    API_PROVIDERS.forEach(provider => {
        if (provider === 'deepl') {
            const apiKey = document.getElementById(`${provider}-apiKey`).value.trim();
            const useFreeApi = document.getElementById(`${provider}-useFreeApi`).checked;
            config[provider] = { apiKey, useFreeApi };
        } else if (provider === 'niutrans') {
            const apiKey = document.getElementById(`${provider}-apiKey`).value.trim();
            config[provider] = { apiKey };
        } else {
            // 其他大模型服务商
            const apiKey = document.getElementById(`${provider}-apiKey`).value.trim();
            const model = document.getElementById(`${provider}-model`).value.trim();
            const temperature = parseFloat(document.getElementById(`${provider}-temperature`).value) || 0.3;
            config[provider] = { apiKey, model, temperature };
        }
    });

    // 高级设置
    config.maxConcurrent = parseInt(document.getElementById('maxConcurrent').value) || 2;
    config.requestDelay = parseInt(document.getElementById('requestDelay').value) || 500;
    config.cacheEnabled = document.getElementById('cacheEnabled').checked;
    config.cacheDuration = parseInt(document.getElementById('cacheDuration').value) || 7;
    config.targetLanguage = 'zh-CN';
    config.translationStyle = '简体中文';
    
    // LLM Prompt 配置
    config.llmSystemPrompt = document.getElementById('llmSystemPrompt').value.trim() || DEFAULT_CONFIG.llmSystemPrompt;
    config.llmUserPrompt = document.getElementById('llmUserPrompt').value.trim() || DEFAULT_CONFIG.llmUserPrompt;

    // 验证配置
    const validation = validateConfig(config);
    if (!validation.valid) {
        showToast('配置错误：' + validation.errors[0], true);
        return;
    }
    
    // 验证 User Prompt 包含 {text} 占位符
    if (!config.llmUserPrompt.includes('{text}')) {
        showToast('配置错误：用户提示词必须包含 {text} 占位符', true);
        return;
    }

    // 保存到 Chrome Storage
    try {
        await browser.storage.sync.set({ translatorConfig: config });
        showToast('设置已保存！');
        console.log('配置已保存：', config);
    } catch (error) {
        showToast('保存失败：' + error.message, true);
    }
}

// 验证配置
function validateConfig(config) {
    const errors = [];
    const apiKeyProviders = ['deepl', 'niutrans', 'openai', 'gemini', 'openrouter', 'lmrouter', 'deepseek', 'siliconflow', 'openai-compatible'];

    // 验证标题提供商
    if (apiKeyProviders.includes(config.titleProvider)) {
        const providerConfig = config[config.titleProvider];
        if (!providerConfig || !providerConfig.apiKey || providerConfig.apiKey.trim() === '') {
            errors.push(`${config.titleProvider} 需要配置 API Key`);
        }
    }

    // 验证摘要提供商
    if (config.abstractProvider && config.abstractProvider.trim() !== '') {
        if (apiKeyProviders.includes(config.abstractProvider)) {
            const providerConfig = config[config.abstractProvider];
            if (!providerConfig || !providerConfig.apiKey || providerConfig.apiKey.trim() === '') {
                errors.push(`${config.abstractProvider} 需要配置 API Key（摘要翻译）`);
            }
        }
    }

    return {
        valid: errors.length === 0,
        errors: errors
    };
}

// 恢复默认设置
async function resetConfig() {
    if (confirm('确定要恢复默认设置吗？')) {
        try {
            await browser.storage.sync.set({ translatorConfig: DEFAULT_CONFIG });
            await loadConfig();
            showToast('已恢复默认设置！');
        } catch (error) {
            showToast('恢复默认设置失败：' + error.message, true);
        }
    }
}

// 折叠/展开功能
function initCollapsible() {
    const collapsibleHeaders = document.querySelectorAll('.collapsible');
    
    collapsibleHeaders.forEach(header => {
        header.addEventListener('click', function() {
            const targetId = this.getAttribute('data-target');
            const content = document.getElementById(targetId);
            const icon = this.querySelector('.collapse-icon');
            
            if (content.style.display === 'none') {
                content.style.display = 'block';
                icon.classList.add('expanded');
            } else {
                content.style.display = 'none';
                icon.classList.remove('expanded');
            }
        });
    });
}

// 清空缓存
async function clearCache() {
    if (confirm('确定要清空所有翻译缓存吗？此操作不可恢复。')) {
        try {
            await browser.storage.local.remove('translationCache');
            showToast('缓存已清空！');
            loadCacheStats();
        } catch (error) {
            showToast('清空缓存失败：' + error.message, true);
        }
    }
}

// 重置 Prompt 为默认值
function resetPrompts() {
    if (confirm('确定要恢复默认的 LLM Prompt 配置吗？')) {
        document.getElementById('llmSystemPrompt').value = DEFAULT_CONFIG.llmSystemPrompt;
        document.getElementById('llmUserPrompt').value = DEFAULT_CONFIG.llmUserPrompt;
        showToast('已恢复默认 Prompt 配置！');
    }
}

// 页面加载时初始化
document.addEventListener('DOMContentLoaded', () => {
    loadConfig();
    initCollapsible();

    // 绑定按钮事件
    document.getElementById('saveBtn').addEventListener('click', saveConfig);
    document.getElementById('resetBtn').addEventListener('click', resetConfig);
    document.getElementById('clearCacheBtn').addEventListener('click', clearCache);
    document.getElementById('resetPromptsBtn').addEventListener('click', resetPrompts);
});
