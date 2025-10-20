/**
 * ╔══════════════════════════════════════════════════════════════════════════════╗
 * ║                            PubMed 文献标题翻译                               ║
 * ║                       PubMed Academic Title Translator                       ║
 * ╚══════════════════════════════════════════════════════════════════════════════╝
 */

(function () {
    'use strict';

    if (typeof window.browser === 'undefined' && typeof window.chrome !== 'undefined') {
        window.browser = window.chrome;
    }

    // ╔══════════════════════════════════════════════════════════════════════════════╗
    // ║                          配置管理 | Configuration                            ║
    // ╚══════════════════════════════════════════════════════════════════════════════╝

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
        // 高级配置：大模型 Prompt
        llmSystemPrompt: 'You are a professional medical and biomedical academic translation assistant. Translate English text into Simplified Chinese with precision, maintaining scientific rigor and professional terminology. Output ONLY the translation result without any explanations or additional content.',
        llmUserPrompt: 'Translate the following English text into Simplified Chinese:\n\n{text}',
    };

    let CONFIG = { ...DEFAULT_CONFIG };

    // 从 Chrome Storage 加载配置
    async function loadConfig() {
        try {
            const result = await browser.storage.sync.get('translatorConfig');
            if (result && result.translatorConfig) {
                CONFIG = { ...DEFAULT_CONFIG, ...result.translatorConfig };
            }
        } catch (error) {
            console.error('配置加载失败：', error);
        }
        return CONFIG;
    }

    // ╔══════════════════════════════════════════════════════════════════════════════╗
    // ║                          翻译缓存系统 | Translation Cache                    ║
    // ╚══════════════════════════════════════════════════════════════════════════════╝

    /**
     * 翻译缓存管理器
     * 使用 Chrome Storage API 持久化缓存
     * 自动清理过期缓存
     */
    class TranslationCache {
        constructor() {
            this.memoryCache = new Map(); // 内存缓存，加速访问
            this.initialized = false;
        }

        /**
         * 初始化缓存，从 Chrome Storage 加载
         */
        async init() {
            if (this.initialized) return;
            
            try {
                const result = await browser.storage.local.get('translationCache');
                if (result.translationCache) {
                    // 加载到内存缓存
                    Object.entries(result.translationCache).forEach(([key, value]) => {
                        this.memoryCache.set(key, value);
                    });
                    console.log(`%c[缓存] 已加载 ${this.memoryCache.size} 条缓存记录`,
                        'color: #9C27B0; font-weight: bold');
                }
                this.initialized = true;
                
                // 清理过期缓存
                await this.cleanExpired();
            } catch (error) {
                console.error('缓存初始化失败：', error);
            }
        }

        /**
         * 生成缓存键
         * 格式：MD5(原文)
         */
        generateKey(text) {
            // 简单哈希函数（用于生成短键名）
            let hash = 0;
            for (let i = 0; i < text.length; i++) {
                const char = text.charCodeAt(i);
                hash = ((hash << 5) - hash) + char;
                hash = hash & hash;
            }
            return `cache_${Math.abs(hash).toString(36)}`;
        }

        /**
         * 从缓存获取翻译
         */
        async get(text) {
            if (!CONFIG.cacheEnabled) return null;
            
            await this.init();
            
            const key = this.generateKey(text);
            const cached = this.memoryCache.get(key);
            
            if (!cached) return null;
            
            // 检查是否过期
            const now = Date.now();
            const expiryTime = cached.timestamp + (CONFIG.cacheDuration * 24 * 60 * 60 * 1000);
            
            if (now > expiryTime) {
                // 缓存已过期，删除
                await this.delete(key);
                console.log('%c[缓存] 缓存已过期，已删除', 'color: #FF9800');
                return null;
            }
            
            console.log(`%c[缓存] 命中缓存 ✓`, 'color: #4CAF50; font-weight: bold');
            return cached.translation;
        }

        /**
         * 保存翻译到缓存
         */
        async set(text, translation) {
            if (!CONFIG.cacheEnabled) return;
            
            await this.init();
            
            const key = this.generateKey(text);
            const cacheEntry = {
                text: text,
                translation: translation,
                timestamp: Date.now()
            };
            
            // 保存到内存缓存
            this.memoryCache.set(key, cacheEntry);
            
            // 保存到持久化存储
            try {
                const cacheObject = {};
                this.memoryCache.forEach((value, key) => {
                    cacheObject[key] = value;
                });
                
                await browser.storage.local.set({ translationCache: cacheObject });
                console.log('%c[缓存] 已保存翻译到缓存', 'color: #2196F3');
            } catch (error) {
                console.error('缓存保存失败：', error);
            }
        }

        /**
         * 删除指定缓存
         */
        async delete(key) {
            this.memoryCache.delete(key);
            
            try {
                const cacheObject = {};
                this.memoryCache.forEach((value, key) => {
                    cacheObject[key] = value;
                });
                await browser.storage.local.set({ translationCache: cacheObject });
            } catch (error) {
                console.error('缓存删除失败：', error);
            }
        }

        /**
         * 清理过期缓存
         */
        async cleanExpired() {
            const now = Date.now();
            const expiryDuration = CONFIG.cacheDuration * 24 * 60 * 60 * 1000;
            let cleanedCount = 0;
            
            for (const [key, value] of this.memoryCache.entries()) {
                if (now - value.timestamp > expiryDuration) {
                    this.memoryCache.delete(key);
                    cleanedCount++;
                }
            }
            
            if (cleanedCount > 0) {
                console.log(`%c[缓存] 已清理 ${cleanedCount} 条过期缓存`,
                    'color: #FF9800; font-weight: bold');
                
                // 更新持久化存储
                const cacheObject = {};
                this.memoryCache.forEach((value, key) => {
                    cacheObject[key] = value;
                });
                await browser.storage.local.set({ translationCache: cacheObject });
            }
        }

        /**
         * 清空所有缓存
         */
        async clear() {
            this.memoryCache.clear();
            await browser.storage.local.remove('translationCache');
            console.log('%c[缓存] 已清空所有缓存', 'color: #f44336; font-weight: bold');
        }

        /**
         * 重置缓存管理器（用于缓存被外部清除后重新初始化）
         */
        reset() {
            this.memoryCache.clear();
            this.initialized = false;
            console.log('%c[缓存] 缓存管理器已重置', 'color: #FF9800; font-weight: bold');
        }

        /**
         * 获取缓存统计信息
         */
        getStats() {
            return {
                count: this.memoryCache.size,
                enabled: CONFIG.cacheEnabled,
                duration: CONFIG.cacheDuration
            };
        }
    }

    // 创建缓存实例
    const translationCache = new TranslationCache();

    // 监听 Chrome Storage 变化，处理缓存被清除的情况
    browser.storage.onChanged.addListener((changes, areaName) => {
        if (areaName === 'local' && changes.translationCache) {
            // 如果缓存被删除（newValue 为 undefined），重置缓存管理器
            if (changes.translationCache.newValue === undefined) {
                console.log('%c[缓存] 检测到缓存已被清除，重置缓存管理器', 
                    'color: #FF9800; font-weight: bold');
                translationCache.reset();
            }
            // 如果缓存被更新，可以选择重新加载（可选）
            else if (changes.translationCache.oldValue !== undefined) {
                console.log('%c[缓存] 检测到缓存已更新', 
                    'color: #2196F3; font-weight: bold');
            }
        }
    });

    // ╔══════════════════════════════════════════════════════════════════════════════╗
    // ║                              工具函数 | Utilities                            ║
    // ╚══════════════════════════════════════════════════════════════════════════════╝

    /**
     * 注入全局样式
     */
    function injectStyles() {
        if (document.getElementById('translation-global-styles')) {
            return;
        }

        const style = document.createElement('style');
        style.id = 'translation-global-styles';
        style.textContent = `
            @keyframes translation-pulse {
                0%, 100% { opacity: 0.4; }
                50% { opacity: 0.8; }
            }
            .translation-loading, .abstract-translation-loading {
                animation: translation-pulse 1.5s ease-in-out infinite;
            }
            .translation-zh {
                display: block;
                margin-top: 4px;
                line-height: 1.4;
                font-style: italic;
                opacity: 0.6;
                font-weight: normal;
            }
            .abstract-translation-container {
                margin-top: 8px;
            }
            .abstract-translation-toggle {
                background: none;
                border: none;
                color: #0071bc;
                cursor: pointer;
                padding: 2px 0;
                font-size: inherit;
                text-decoration: underline;
                opacity: 0.7;
                font-weight: normal;
            }
            .abstract-translation-toggle:hover {
                opacity: 1;
            }
            .abstract-translation-zh {
                display: none;
                margin-top: 8px;
                line-height: 1.6;
                font-size: inherit;
                opacity: 0.65;
                font-weight: normal;
            }
        `;
        document.head.appendChild(style);
    }

    /**
     * 翻译队列管理器
     * 策略：每个渠道先测试一个请求，成功后再开启并发
     */
    class TranslationQueue {
        constructor(maxConcurrent, delay) {
            this.maxConcurrent = maxConcurrent;
            this.delay = delay;
            this.queue = [];
            this.activeCount = 0;
            this.providerTested = {}; // 记录每个提供商是否已测试成功
        }

        async add(translateFunc, type = 'title', provider = 'unknown') {
            return new Promise((resolve, reject) => {
                this.queue.push({ translateFunc, resolve, reject, type, provider });
                this.process();
            });
        }

        async process() {
            while (this.activeCount < this.maxConcurrent && this.queue.length > 0) {
                const { translateFunc, resolve, reject, type, provider } = this.queue.shift();
                
                // 检查该类型的翻译是否已停止
                if (scriptStopped[type]) {
                    reject(new Error(`${type === 'title' ? '标题' : '摘要'}翻译已停止`));
                    continue;
                }
                
                // 检查该提供商是否需要测试
                const providerKey = `${type}_${provider}`;
                const needTest = !this.providerTested[providerKey];
                
                // 如果需要测试且还有其他任务在执行，等待
                if (needTest && this.activeCount > 0) {
                    // 将任务放回队列前端
                    this.queue.unshift({ translateFunc, resolve, reject, type, provider });
                    break;
                }
                
                this.activeCount++;

                (async () => {
                    try {
                        const result = await translateFunc();
                        
                        // 标记该提供商测试成功
                        if (needTest) {
                            this.providerTested[providerKey] = true;
                            console.log(`%c[队列] ${type === 'title' ? '标题' : '摘要'}翻译（${provider}）测试成功，开启并发模式`,
                                'color: #4CAF50; font-weight: bold');
                        }
                        
                        resolve(result);
                    } catch (error) {
                        reject(error);
                    } finally {
                        this.activeCount--;
                        if (this.queue.length > 0) {
                            setTimeout(() => this.process(), this.delay);
                        }
                    }
                })();
            }
        }

        /**
         * 清空指定类型的所有待处理任务
         */
        clearType(type) {
            const remainingQueue = [];
            let clearedCount = 0;
            
            while (this.queue.length > 0) {
                const task = this.queue.shift();
                if (task.type === type) {
                    // 拒绝该类型的任务
                    task.reject(new Error(`${type === 'title' ? '标题' : '摘要'}翻译已停止`));
                    clearedCount++;
                } else {
                    // 保留其他类型的任务
                    remainingQueue.push(task);
                }
            }
            this.queue = remainingQueue;
            
            if (clearedCount > 0) {
                console.log(`%c[队列] 已清空 ${clearedCount} 个${type === 'title' ? '标题' : '摘要'}翻译任务，剩余 ${this.queue.length} 个任务`,
                    'color: #FF9800; font-weight: bold');
            }
        }
    }

    let translationQueue;
    const failureCount = {
        title: {},    // 标题翻译失败计数
        abstract: {}  // 摘要翻译失败计数
    };
    const MAX_FAILURES = 3;
    const scriptStopped = {
        title: false,     // 标题翻译是否停止
        abstract: false   // 摘要翻译是否停止
    };
    let alertShown = {
        title: false,     // 标题错误弹窗是否已显示
        abstract: false   // 摘要错误弹窗是否已显示
    };

    /**
     * 检测文本是否主要是中文
     */
    function isChinese(text) {
        if (!text || text.trim().length === 0) return false;
        const chineseRegex = /[\u4e00-\u9fa5]/g;
        const chineseChars = text.match(chineseRegex);
        if (!chineseChars) return false;
        const chineseRatio = chineseChars.length / text.length;
        return chineseRatio > 0.5;
    }

    /**
     * 使用 Chrome Extension Message Passing 发起请求（绕过 CORS）
     */
    async function makeRequest(url, options = {}) {
        try {
            // 通过 background script 发起请求以绕过 CORS
            const response = await browser.runtime.sendMessage({
                action: 'makeRequest',
                url: url,
                options: {
                    method: options.method || 'GET',
                    headers: options.headers || {},
                    body: options.data || options.body
                }
            });

            if (response.error) {
                throw new Error(response.error);
            }

            return response.data;
        } catch (error) {
            throw new Error(`网络请求失败：${error.message}`);
        }
    }

    /**
     * Google 翻译
     */
    async function translateWithGoogle(text) {
        const url = `https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=zh-CN&dt=t&q=${encodeURIComponent(text)}`;
        const result = await makeRequest(url, {
            headers: { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36' }
        });

        if (result && result[0]) {
            let translation = '';
            result[0].forEach(item => {
                if (item[0]) translation += item[0];
            });
            return translation.trim();
        }
        throw new Error('Google 翻译返回格式错误');
    }

    /**
     * Microsoft 翻译
     */
    async function translateWithMicrosoft(text) {
        const authToken = await makeRequest('https://edge.microsoft.com/translate/auth');
        const result = await makeRequest(
            'https://api.cognitive.microsofttranslator.com/translate?api-version=3.0&to=zh-Hans&from=en',
            {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Authorization': `Bearer ${authToken}`
                },
                body: JSON.stringify([{ text: text }])
            }
        );

        if (result && result[0] && result[0].translations && result[0].translations[0]) {
            return result[0].translations[0].text.trim();
        }
        throw new Error('Microsoft 翻译返回格式错误');
    }

    /**
     * DeepL 翻译
     */
    async function translateWithDeepL(text) {
        if (!CONFIG.deepl.apiKey) {
            throw new Error('DeepL API Key 未配置');
        }

        const baseUrl = CONFIG.deepl.useFreeApi
            ? 'https://api-free.deepl.com/v2/translate'
            : 'https://api.deepl.com/v2/translate';

        const params = new URLSearchParams({
            text: text,
            target_lang: 'ZH',
            auth_key: CONFIG.deepl.apiKey
        });

        const result = await makeRequest(baseUrl, {
            method: 'POST',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: params.toString()
        });

        if (result.translations && result.translations[0]) {
            return result.translations[0].text;
        }
        throw new Error('DeepL 翻译响应格式错误');
    }

    /**
     * 小牛翻译
     */
    async function translateWithNiutrans(text) {
        if (!CONFIG.niutrans.apiKey) {
            throw new Error('小牛翻译 API Key 未配置');
        }

        const result = await makeRequest('https://api.niutrans.com/NiuTransServer/translation', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                src_text: text,
                from: 'en',
                to: 'zh',
                apikey: CONFIG.niutrans.apiKey
            })
        });

        if (result.tgt_text) {
            return result.tgt_text.trim();
        } else if (result.error_msg) {
            throw new Error(`小牛翻译错误：${result.error_msg}`);
        }
        throw new Error('小牛翻译返回格式错误');
    }

    /**
     * 大模型翻译（通用）
     */
    async function translateWithLLM(text, provider) {
        const config = CONFIG[provider];
        if (!config || !config.apiKey) {
            throw new Error(`${provider} API Key 未配置`);
        }

        const baseURLMap = {
            'openai': 'https://api.openai.com/v1',
            'gemini': 'https://generativelanguage.googleapis.com/v1beta/openai',
            'openrouter': 'https://openrouter.ai/api/v1',
            'lmrouter': 'https://api.lmrouter.com/openai/v1',
            'deepseek': 'https://api.deepseek.com',
            'siliconflow': 'https://api.siliconflow.cn/v1'
        };

        const baseURL = baseURLMap[provider];
        if (!baseURL) {
            throw new Error(`未知的服务商或 baseURL 未配置：${provider}`);
        }

        // 使用配置的 prompt，支持 {text} 占位符
        const systemPrompt = CONFIG.llmSystemPrompt || DEFAULT_CONFIG.llmSystemPrompt;
        const userPromptTemplate = CONFIG.llmUserPrompt || DEFAULT_CONFIG.llmUserPrompt;
        const userPrompt = userPromptTemplate.replace('{text}', text);

        const messages = [
            {
                role: 'system',
                content: systemPrompt
            },
            {
                role: 'user',
                content: userPrompt
            }
        ];

        const result = await makeRequest(`${baseURL}/chat/completions`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'Authorization': `Bearer ${config.apiKey}`
            },
            body: JSON.stringify({
                model: config.model,
                messages: messages,
                temperature: config.temperature || 0.3
            })
        });

        if (result.choices && result.choices[0] && result.choices[0].message) {
            return result.choices[0].message.content.trim();
        }
        throw new Error(`${provider} 翻译返回格式错误`);
    }

    /**
     * 翻译函数
     */
    async function translate(text, type = 'title') {
        // 检查对应类型的翻译是否已停止
        if (scriptStopped[type]) {
            throw new Error(`${type === 'title' ? '标题' : '摘要'}翻译已因连续失败而停止，请检查配置`);
        }

        // 检查缓存
        const cachedTranslation = await translationCache.get(text);
        if (cachedTranslation) {
            return cachedTranslation;
        }

        let provider;
        if (type === 'abstract' && CONFIG.abstractProvider) {
            provider = CONFIG.abstractProvider;
        } else {
            provider = CONFIG.titleProvider;
        }

        const typeText = type === 'abstract' ? '摘要' : '标题';
        const preview = text.length > 50 ? text.substring(0, 50) + '...' : text;
        console.log(`%c[翻译${typeText}] %c使用 ${provider} 翻译：%c${preview}`,
            'color: #4CAF50; font-weight: bold',
            'color: #2196F3',
            'color: #666');

        let translateFunc;
        const llmProviders = ['openai', 'gemini', 'openrouter', 'lmrouter', 'deepseek', 'siliconflow'];

        if (llmProviders.includes(provider)) {
            translateFunc = () => translateWithLLM(text, provider);
        } else {
            switch (provider) {
                case 'google': translateFunc = () => translateWithGoogle(text); break;
                case 'microsoft': translateFunc = () => translateWithMicrosoft(text); break;
                case 'deepl': translateFunc = () => translateWithDeepL(text); break;
                case 'niutrans': translateFunc = () => translateWithNiutrans(text); break;
                default: throw new Error(`未知的 API 提供商：${provider}`);
            }
        }

        try {
            const result = await translationQueue.add(translateFunc, type, provider);
            // 重置对应渠道和类型的失败计数
            if (!failureCount[type][provider]) {
                failureCount[type][provider] = 0;
            }
            failureCount[type][provider] = 0;
            console.log(`%c[翻译成功] %c${result}`, 'color: #4CAF50; font-weight: bold', 'color: #333');
            
            // 保存到缓存
            await translationCache.set(text, result);
            
            return result;
        } catch (error) {
            // 如果翻译已停止，直接抛出错误，不增加计数
            if (scriptStopped[type]) {
                throw error;
            }
            
            // 为每个类型和提供商单独计数
            if (!failureCount[type][provider]) {
                failureCount[type][provider] = 0;
            }
            failureCount[type][provider]++;
            
            console.error(`%c[翻译失败] %c${typeText}翻译（${provider}）失败（${failureCount[type][provider]}/${MAX_FAILURES}）：%c${error}`,
                'color: #f44336; font-weight: bold',
                'color: #2196F3',
                'color: #f44336');

            if (failureCount[type][provider] >= MAX_FAILURES && !alertShown[type]) {
                // 立即停止该类型的翻译
                scriptStopped[type] = true;
                alertShown[type] = true;
                
                // 清空队列中该类型的所有待处理任务
                translationQueue.clearType(type);
                
                const message = `${typeText}翻译（${provider}）连续失败 ${MAX_FAILURES} 次，已停止。请检查配置后刷新页面重试。`;
                console.error(`%c[严重错误] %c${message}`,
                    'color: #f44336; font-weight: bold; font-size: 14px',
                    'color: #f44336; font-size: 14px');
                
                // 立即同步弹窗（只弹一次）
                alert(`⚠️ PubMed 翻译插件错误\n\n${message}\n\n✓ ${typeText}翻译已停止\n${type === 'title' ? '✓ 摘要翻译继续运行' : '✓ 标题翻译继续运行'}`);
            }
            throw error;
        }
    }

    /**
     * 默认的文本获取函数
     */
    function defaultGetText(element) {
        const clone = element.cloneNode(true);
        const existingTranslation = clone.querySelector('.translation-zh');
        if (existingTranslation) existingTranslation.remove();
        return clone.textContent.trim();
    }

    /**
     * 默认的标题翻译创建函数
     */
    function defaultCreateTranslation(element, translation) {
        if (element.querySelector('.translation-zh')) return;
        const translationSpan = document.createElement('span');
        translationSpan.className = 'translation-zh';
        translationSpan.textContent = translation;
        element.appendChild(translationSpan);
    }

    /**
     * 为摘要元素添加翻译
     */
    async function addAbstractTranslation(abstractElement, getTextFunc) {
        if (!CONFIG.translateAbstract || scriptStopped.abstract) return;
        if (abstractElement.dataset.translated === 'true' || abstractElement.dataset.translating === 'true') return;
        if (abstractElement.querySelector('.abstract-translation-container') ||
            abstractElement.parentElement.querySelector('.abstract-translation-container')) {
            abstractElement.dataset.translated = 'true';
            return;
        }

        const originalText = getTextFunc(abstractElement);
        if (!originalText || originalText.trim().length === 0 || isChinese(originalText)) {
            abstractElement.dataset.translated = 'true';
            return;
        }

        const loadingDiv = document.createElement('div');
        loadingDiv.className = 'abstract-translation-loading';
        loadingDiv.style.cssText = 'margin-top: 8px; font-style: italic; opacity: 0.6;';
        loadingDiv.textContent = '正在翻译摘要...';
        abstractElement.parentElement.insertBefore(loadingDiv, abstractElement.nextSibling);

        try {
            abstractElement.dataset.translating = 'true';
            const translation = await translate(originalText, 'abstract');
            
            if (loadingDiv && loadingDiv.parentElement) {
                loadingDiv.remove();
            }

            if (abstractElement.querySelector('.abstract-translation-container') ||
                abstractElement.parentElement.querySelector('.abstract-translation-container')) {
                abstractElement.dataset.translated = 'true';
                abstractElement.dataset.translating = 'false';
                return;
            }

            const collapseContainer = document.createElement('div');
            collapseContainer.className = 'abstract-translation-container';
            collapseContainer.style.display = 'none';

            const toggleButton = document.createElement('button');
            toggleButton.className = 'abstract-translation-toggle';
            toggleButton.textContent = '▶ 显示中文翻译';

            const translationDiv = document.createElement('div');
            translationDiv.className = 'abstract-translation-zh';
            translationDiv.style.display = 'none';
            translationDiv.textContent = translation;

            toggleButton.addEventListener('click', function () {
                const isVisible = translationDiv.style.display === 'block';
                if (isVisible) {
                    translationDiv.style.display = 'none';
                    toggleButton.textContent = '▶ 显示中文翻译';
                } else {
                    translationDiv.style.display = 'block';
                    toggleButton.textContent = '▼ 收起中文翻译';
                }
            });

            collapseContainer.appendChild(toggleButton);
            collapseContainer.appendChild(translationDiv);
            abstractElement.parentElement.insertBefore(collapseContainer, abstractElement.nextSibling);

            setTimeout(() => {
                collapseContainer.style.display = 'block';
            }, 10);

            abstractElement.dataset.translated = 'true';
            abstractElement.dataset.translating = 'false';
        } catch (error) {
            if (loadingDiv && loadingDiv.parentElement) {
                loadingDiv.remove();
            }
            console.error(`%c[摘要翻译失败] %c${error}`, 'color: #f44336; font-weight: bold', 'color: #f44336');
            abstractElement.dataset.translating = 'false';
        }
    }

    /**
     * 为标题元素添加翻译
     */
    async function addTranslation(titleElement, getTextFunc, createTranslationFunc) {
        if (scriptStopped.title) return;
        if (titleElement.dataset.translated === 'true' || titleElement.dataset.translating === 'true') return;

        const existingTranslation = titleElement.querySelector('.translation-zh') ||
            titleElement.parentElement?.querySelector('.translation-zh');
        if (existingTranslation) {
            titleElement.dataset.translated = 'true';
            return;
        }

        const originalText = getTextFunc(titleElement);
        if (!originalText || originalText.trim().length === 0 || isChinese(originalText)) {
            titleElement.dataset.translated = 'true';
            return;
        }

        const loadingElement = document.createElement('span');
        loadingElement.className = 'translation-loading translation-zh';
        loadingElement.textContent = '翻译中...';
        titleElement.appendChild(loadingElement);

        try {
            titleElement.dataset.translating = 'true';
            const translation = await translate(originalText, 'title');

            if (loadingElement && loadingElement.parentElement) {
                loadingElement.remove();
            }

            const checkExisting = titleElement.querySelector('.translation-zh') ||
                titleElement.parentElement?.querySelector('.translation-zh');
            if (checkExisting) {
                titleElement.dataset.translated = 'true';
                titleElement.dataset.translating = 'false';
                return;
            }

            createTranslationFunc(titleElement, translation);
            titleElement.dataset.translated = 'true';
            titleElement.dataset.translating = 'false';
        } catch (error) {
            if (loadingElement && loadingElement.parentElement) {
                loadingElement.remove();
            }
            console.error(`%c[标题翻译失败] %c${error}`, 'color: #f44336; font-weight: bold', 'color: #f44336');
            titleElement.dataset.translating = 'false';
        }
    }

    // ╔══════════════════════════════════════════════════════════════════════════════╗
    // ║                        网站特定处理 | Site Processors                        ║
    // ╚══════════════════════════════════════════════════════════════════════════════╝

    async function processPubMed() {
        const titleElements = [];

        const trendingArticles = document.querySelectorAll('.homepage-trending-and-latest .full-docsum a[href^="/"]');
        trendingArticles.forEach(titleElement => {
            if (!titleElement.querySelector('.docsum-authors') && !titleElement.classList.contains('see-more')) {
                titleElements.push({
                    element: titleElement,
                    getText: defaultGetText,
                    createTranslation: defaultCreateTranslation
                });
            }
        });

        const docsumTitles = document.querySelectorAll('.docsum-title');
        docsumTitles.forEach(titleElement => {
            titleElements.push({
                element: titleElement,
                getText: defaultGetText,
                createTranslation: defaultCreateTranslation
            });
        });

        const detailTitleSelectors = ['h1.heading-title', '.heading-title', 'h1[class*="heading"]', 'main h1', 'article h1'];
        let detailTitle = null;
        for (const selector of detailTitleSelectors) {
            const elements = document.querySelectorAll(selector);
            for (const el of elements) {
                if (el.textContent.trim().length > 0 &&
                    !el.closest('.similar-articles') &&
                    !el.closest('.articles-from-the-same-journal') &&
                    !el.classList.contains('docsum-title')) {
                    detailTitle = el;
                    break;
                }
            }
            if (detailTitle) break;
        }

        if (detailTitle) {
            titleElements.push({
                element: detailTitle,
                getText: defaultGetText,
                createTranslation: defaultCreateTranslation
            });
        }

        // 判断标题和摘要是否使用同一渠道
        const titleProvider = CONFIG.titleProvider;
        const abstractProvider = CONFIG.abstractProvider || CONFIG.titleProvider;
        const useSameProvider = (titleProvider === abstractProvider);

        // 翻译标题
        await Promise.all(titleElements.map(item =>
            addTranslation(item.element, item.getText, item.createTranslation)
        ));

        // 处理摘要翻译
        if (CONFIG.translateAbstract) {
            const abstractElement = document.querySelector('div.abstract#abstract');
            if (abstractElement) {
                // 如果使用同一渠道，等标题翻译完成后再翻译摘要
                // 如果使用不同渠道，可以与标题翻译并行
                if (useSameProvider) {
                    // 标题已经翻译完成，现在翻译摘要
                    await addAbstractTranslation(
                        abstractElement,
                        (el) => {
                            const clone = el.cloneNode(true);
                            const title = clone.querySelector('h2.title');
                            if (title) title.remove();
                            const keywords = clone.querySelector('p strong.sub-title');
                            if (keywords && keywords.textContent.includes('Keywords')) {
                                keywords.parentElement.remove();
                            }
                            const existingTranslation = clone.querySelector('.abstract-translation-zh');
                            if (existingTranslation) existingTranslation.remove();
                            return clone.textContent.trim();
                        }
                    );
                } else {
                    // 不同渠道，可以立即开始摘要翻译（与标题并行）
                    addAbstractTranslation(
                        abstractElement,
                        (el) => {
                            const clone = el.cloneNode(true);
                            const title = clone.querySelector('h2.title');
                            if (title) title.remove();
                            const keywords = clone.querySelector('p strong.sub-title');
                            if (keywords && keywords.textContent.includes('Keywords')) {
                                keywords.parentElement.remove();
                            }
                            const existingTranslation = clone.querySelector('.abstract-translation-zh');
                            if (existingTranslation) existingTranslation.remove();
                            return clone.textContent.trim();
                        }
                    );
                }
            }
        }
    }

    async function processEuropePMC() {
        const detailTitleSelectors = ['h1#article--current--title', 'h1.article-metadata-title', 'h1[id*="article"][id*="title"]'];
        let detailTitle = null;
        for (const selector of detailTitleSelectors) {
            detailTitle = document.querySelector(selector);
            if (detailTitle && detailTitle.textContent.trim().length > 0) break;
            detailTitle = null;
        }

        if (detailTitle) {
            addTranslation(detailTitle, defaultGetText, defaultCreateTranslation);
        }

        const titleElements = [];
        const citationTitles = document.querySelectorAll('h3.citation-title a');
        citationTitles.forEach(titleElement => {
            titleElements.push({
                element: titleElement,
                getText: defaultGetText,
                createTranslation: defaultCreateTranslation
            });
        });

        await Promise.all(titleElements.map(item =>
            addTranslation(item.element, item.getText, item.createTranslation)
        ));

        if (CONFIG.translateAbstract) {
            const abstractSelectors = ['div#article--abstract--content.abstract', 'div.abstract-content#eng-abstract'];
            let abstractElement = null;
            for (const selector of abstractSelectors) {
                abstractElement = document.querySelector(selector);
                if (abstractElement && abstractElement.textContent.trim().length > 0) break;
                abstractElement = null;
            }

            if (abstractElement) {
                await addAbstractTranslation(
                    abstractElement,
                    (el) => {
                        const clone = el.cloneNode(true);
                        const existingTranslation = clone.querySelector('.abstract-translation-zh');
                        if (existingTranslation) existingTranslation.remove();
                        return clone.textContent.trim();
                    }
                );
            }
        }
    }

    async function processSemanticScholar() {
        const detailTitle = document.querySelector('h1[data-test-id="paper-detail-title"]');
        if (detailTitle && detailTitle.textContent.trim().length > 0) {
            addTranslation(detailTitle, defaultGetText, defaultCreateTranslation);
        }

        const titleElements = [];
        const paperTitles = document.querySelectorAll('.cl-paper-title');
        paperTitles.forEach(titleElement => {
            titleElements.push({
                element: titleElement,
                getText: defaultGetText,
                createTranslation: defaultCreateTranslation
            });
        });

        await Promise.all(titleElements.map(item =>
            addTranslation(item.element, item.getText, item.createTranslation)
        ));
    }

    async function processGoogleScholar() {
        const titleElements = [];
        const searchTitles = document.querySelectorAll('h3.gs_rt');
        searchTitles.forEach(titleElement => {
            titleElements.push({
                element: titleElement,
                getText: defaultGetText,
                createTranslation: defaultCreateTranslation
            });
        });

        await Promise.all(titleElements.map(item =>
            addTranslation(item.element, item.getText, item.createTranslation)
        ));
    }

    function processCurrentSite() {
        const hostname = window.location.hostname;
        if (hostname.includes('pubmed.ncbi.nlm.nih.gov')) {
            processPubMed();
        } else if (hostname.includes('europepmc.org')) {
            processEuropePMC();
        } else if (hostname.includes('semanticscholar.org')) {
            processSemanticScholar();
        } else if (hostname.includes('scholar.google')) {
            processGoogleScholar();
        }
    }

    function observeChanges() {
        let timeoutId = null;
        const observer = new MutationObserver((mutations) => {
            if (timeoutId) clearTimeout(timeoutId);
            timeoutId = setTimeout(() => {
                processCurrentSite();
                timeoutId = null;
            }, 500);
        });
        observer.observe(document.body, { childList: true, subtree: true });
    }

    // ╔══════════════════════════════════════════════════════════════════════════════╗
    // ║                              初始化 | Initialize                             ║
    // ╚══════════════════════════════════════════════════════════════════════════════╝

    async function init() {
        console.log('%cPubMed 文献标题翻译', 'color: #4CAF50; font-size: 16px; font-weight: bold');

        await loadConfig();
        translationQueue = new TranslationQueue(CONFIG.maxConcurrent, CONFIG.requestDelay);

        const providerNameMap = {
            'google': 'Google 翻译',
            'microsoft': 'Microsoft 翻译',
            'deepl': 'DeepL 翻译',
            'niutrans': '小牛翻译',
            'openai': 'OpenAI',
            'gemini': 'Google AI Studio (Gemini)',
            'openrouter': 'OpenRouter',
            'lmrouter': 'LMRouter',
            'deepseek': 'DeepSeek',
            'siliconflow': '硅基流动'
        };

        const titleProviderName = providerNameMap[CONFIG.titleProvider] || CONFIG.titleProvider;
        const abstractProviderName = CONFIG.abstractProvider
            ? (providerNameMap[CONFIG.abstractProvider] || CONFIG.abstractProvider)
            : '与标题相同';

        console.log('%c[配置信息]', 'color: #FF9800; font-weight: bold');
        console.log(`  标题翻译提供商：%c${titleProviderName}`, 'color: #2196F3; font-weight: bold');
        console.log(`  摘要翻译提供商：%c${abstractProviderName}`, 'color: #2196F3; font-weight: bold');
        console.log(`  摘要翻译开关：%c${CONFIG.translateAbstract ? '已启用' : '已关闭'}`,
            CONFIG.translateAbstract ? 'color: #4CAF50; font-weight: bold' : 'color: #999');
        console.log(`  翻译缓存：%c${CONFIG.cacheEnabled ? '已启用' : '已关闭'}`,
            CONFIG.cacheEnabled ? 'color: #4CAF50; font-weight: bold' : 'color: #999');
        if (CONFIG.cacheEnabled) {
            console.log(`  缓存有效期：${CONFIG.cacheDuration} 天`);
        }

        // 初始化缓存
        await translationCache.init();
        const cacheStats = translationCache.getStats();
        if (cacheStats.enabled) {
            console.log(`  缓存记录数：${cacheStats.count} 条`);
        }

        injectStyles();
        processCurrentSite();
        observeChanges();

        console.log('%c[插件已启动] 正在监听页面变化...', 'color: #4CAF50; font-weight: bold');
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
