// ==UserScript==
// @name         PubMed 文献标题翻译 | PubMed Academic Title Translator
// @namespace    https://github.com/
// @version      1.0
// @description  自动翻译 PubMed、Europe PMC、Semantic Scholar、Google Scholar 等学术网站上的论文标题和摘要为中文 | Auto-translate academic paper titles and abstracts to Chinese
// @description:zh-CN  自动翻译学术网站上的论文标题和摘要为中文，支持多种翻译 API
// @description:en  Auto-translate academic paper titles and abstracts to Chinese with multiple translation APIs
// @author       Miao
// @coauthor     Claude Sonnet 4.5
// @license      MIT
// @icon         data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIGhlaWdodD0iODAwIiB3aWR0aD0iMTIwMCIgdmlld0JveD0iLTE4LjQ2NSAtMTAuOTIyNzUgMTYwLjAzIDY1LjUzNjUiPjxwYXRoIGQ9Ik01MC40ODcgMi4wNHYyOS4wMzRzMTEuMTYyLTEuMjk5IDExLjE2MiA5LjYwNFYxMy4yMDFjMC0xMC4zODMtMTEuMTYyLTExLjE2MS0xMS4xNjItMTEuMTYxIiBmaWxsPSIjMjMxRjFGIi8+PHBhdGggZD0iTTU1LjcxNSAwdjI1LjU0N3M2LjE2MiAxLjE4OSA2LjE2MiAxMi4wOTFjMCAxMC45MDMuMDMxLTIwLjI4My4wMzEtMjYuMTI0QzYxLjkwOSAxLjEzMiA1NS43MTUgMCA1NS43MTUgMCIgZmlsbD0iI0FBQSIvPjxwYXRoIGQ9Ik02Mi4wNzcgMTIuOTQxdjI2LjQyMnM1LjM1OS0xNS4wMSAyNy44ODcgNC4zMjhjMC03LjAwOC4wNDMtMjQuNjgzLjA0My0zMC41MjUtMjIuMjY4LTE2LjIyMy0yNy45My0uMjI1LTI3LjkzLS4yMjVNMCAzMi43MThoNXYtNi4zOTloMi44NDhjNC4zODggMCA2Ljg1Mi0xLjk5NiA2Ljg1Mi02LjU1IDAtNC40MjctMi44NjktNi4zNDktNy4wMTgtNi4zNDlIMHptNS0xNS4yOTloLjg1M2MxLjk2NSAwIDMuNjQ2LjAyNyAzLjY0NiAyLjUwMyAwIDIuMzk2LTEuODEgMi4zOTYtMy42NDYgMi4zOTZINXptMTEuNjk5IDIuMnY3Ljg3MWMwIDQuMzA0IDMuMDczIDUuNjI5IDcuMDUgNS42MjlTMzAuOCAzMS43OTUgMzAuOCAyNy40OXYtNy44NzFoLTQuN3Y2Ljk3NGMwIDEuNjU0LS40MTQgMi44MjUtMi4zNTEgMi44MjVzLTIuMzUtMS4xNzEtMi4zNS0yLjgyNXYtNi45NzR6TTMzLjYgMzIuNzE4aDQuN3YtMS40NTloLjA1MWMuODQxIDEuMjgyIDIuNDIgMS44NTkgMy45NDkgMS44NTkgMy44OTggMCA2LjYtMy4yMjUgNi42LTcuMDEzIDAtMy43NjQtMi42NzctNi45ODgtNi41NDktNi45ODgtMS41MDMgMC0zLjA1Ny41NzQtNC4wNSAxLjc0N3YtOS4zNDdoLTQuN3ptNy41LTkuNmMxLjg5NyAwIDMgMS4zNzggMyAzLjAxNCAwIDEuNjg4LTEuMTAyIDIuOTg2LTMgMi45ODYtMS44OTcgMC0zLTEuMjk4LTMtMi45ODYgMC0xLjYzNiAxLjEwMi0zLjAxNCAzLTMuMDE0eiIgZmlsbD0iIzM5NzhBRCIvPjxwYXRoIGZpbGw9IiNGRkYiIGQ9Ik03MC44MDUgMjEuNjA3aC4wNTFsNC40MyAxMS4xMTFoMS45OThsNC42MzQtMTEuMTExaC4wNTFsMS40MDggMTEuMTExaDUuMDIybC0yLjkyMi0xOS4yOTloLTQuOTkybC00LjE0OSAxMC4zMTQtMy45MTgtMTAuMzE0aC00Ljk0MUw2NC4yIDMyLjcxOGg0Ljk5MnoiLz48cGF0aCBkPSJNOTYuNyAyNC4yMThjLjI4MS0xLjM3NCAxLjQwOC0yLjEgMi43NjQtMi4xIDEuMjU0IDAgMi40MDYuODMgMi42MzkgMi4xem05LjcyNiAyLjIxM2MwLTQuNDktMi42NS03LjMxMy03LjIyNy03LjMxMy00LjI5MyAwLTcuMjk5IDIuNjM2LTcuMjk5IDcuMDEzIDAgNC41MyAzLjI2NCA2Ljk4NyA3LjYzNyA2Ljk4NyAzLjAwOCAwIDUuOTY1LTEuNDA2IDYuNzExLTQuNWgtNC40OTJjLS41MTIuODY5LTEuMjMgMS4yMDEtMi4yMyAxLjIwMS0xLjkyNCAwLTIuOTI2LTEuMDE5LTIuOTI2LTIuOTAxaDkuODI2em0xMS45NzMgNi4yODdoNC43MDF2LTIxLjJoLTQuNzAxdjkuMzQ3Yy0uOTY5LTEuMTczLTIuNTQ5LTEuNzQ3LTQuMDUxLTEuNzQ3LTMuODczIDAtNi41NDkgMy4yMjUtNi41NDkgNi45ODdzMi43MjcgNy4wMTIgNi42IDcuMDEyYzEuNTI3IDAgMy4xMzMtLjU3OCAzLjk0Ny0xLjg1OWguMDUzem0tMi43OTktOS42YzEuODk2IDAgMyAxLjM3OCAzIDMuMDE0IDAgMS42ODgtMS4xMDIgMi45ODYtMyAyLjk4Ni0xLjg5NiAwLTMtMS4yOTgtMy0yLjk4NiAwLTEuNjM2IDEuMTAyLTMuMDE0IDMtMy4wMTR6IiBmaWxsPSIjMzk3OEFEIi8+PC9zdmc+
// @downloadURL  https://raw.githubusercontent.com/aoaim/LuanQiBaZao/main/js/pubmed-translator.user.js
// @updateURL    https://raw.githubusercontent.com/aoaim/LuanQiBaZao/main/js/pubmed-translator.user.js
// @match        https://pubmed.ncbi.nlm.nih.gov/*
// @match        https://europepmc.org/*
// @match        https://www.semanticscholar.org/*
// @match        https://scholar.google.com/*
// @match        https://scholar.google.co.*/*
// @grant        GM_xmlhttpRequest
// @connect      translate.googleapis.com
// @connect      edge.microsoft.com
// @connect      api.cognitive.microsofttranslator.com
// @connect      api-free.deepl.com
// @connect      api.deepl.com
// @connect      api.niutrans.com
// @connect      *
// @run-at       document-idle
// ==/UserScript==

(function () {
    'use strict';

    /**
     * ╔══════════════════════════════════════════════════════════════════════════════╗
     * ║                          PubMed 文献标题翻译 v1.0                            ║
     * ║                       PubMed Academic Title Translator                       ║
     * ║                   Build by Miao and Claude Sonnet 4.5 with ♥                 ║
     * ╚══════════════════════════════════════════════════════════════════════════════╝
     * ╔══════════════════════════════════════════════════════════════════════════════╗
     * ║                            使用说明（新手必读）                              ║
     * ╚══════════════════════════════════════════════════════════════════════════════╝
     * 
     * 【快速开始 - 零基础也能用】
     * 
     * [1] 第一步：安装 Violentmonkey/Userscripts/Tampermonkey 浏览器插件
     *     - Chrome/Edge: 在扩展商店搜索 "Violentmonkey" 并安装
     *     - Firefox: 在附加组件商店搜索 "Violentmonkey" 并安装
     *     - Safari: 在 App Store 搜索 "Userscripts" 或者 "Tampermonkey" 并安装
     * 
     * [2] 第二步：安装本脚本
     *     - 点击 Violentmonkey 图标 → + Creat a new script → 粘贴代码 → Save & Close
     *     - 点击 Userscripts 图标 → Open Extension Page → + New JS → 粘贴代码 → Save
     *     - 或者：新建脚本，复制粘贴本脚本全部内容，按 Ctrl+S 保存
     * 
     * [3] 第三步：开始使用
     *     - 打开 PubMed、Google Scholar 等学术网站
     *     - 脚本会自动翻译论文标题为中文
     *     - 翻译结果显示在原标题下方，斜体灰色
     * 
     * 【默认配置 - 开箱即用】
     * 
     * + 使用微软免费翻译（无需注册，无需 API Key）
     * + 自动翻译所有论文标题
     * + 默认不翻译摘要（避免干扰阅读）
     * 
     * 【进阶配置（可选）】
     * 
     * 如果你想自定义配置，请往下滚动到 "配置区域"，修改 CONFIG 对象：
     * 
     * [*] 修改翻译服务商：
     *     titleProvider: 'microsoft'  // 改成 'google' 或 'deepl' 或 'openai'
     * 
     * [*] 启用摘要翻译：
     *     translateAbstract: true  // 改成 true 启用，false 关闭（默认）
     * 
     * [*] 使用大模型翻译（需要 API Key）：
     *     第 1 步：申请 API Key
     *     
     *     第 2 步：填入配置（找到下面的 openai 配置项）：
     *       openai: {
     *           apiKey: '这里填入你的 API Key',  // 把引号里的内容替换成你的 Key
     *           model: 'gpt-5-mini',              // 根据服务商选择模型
     *           baseURL: 'https://api.openai.com/v1'  // 根据服务商修改地址
     *       }
     *     
     *     第 3 步：修改翻译提供商：
     *       titleProvider: 'openai'  // 或者改成其他的提供商
     * 
     * 【详细功能说明】
     *
     * 本脚本自动翻译文献搜索引擎网站上的论文标题为中文，支持以下网站和页面：
     *
     * 【PubMed】
     * 1. 主页 - Trending Articles 论文标题
     * 2. 搜索结果页 - 论文标题列表
     * 3. 文章详情页 - 主标题
     * 4. 文章详情页 - Similar articles 论文标题（动态加载）
     * 5. 文章详情页 - Cited by 论文标题（动态加载）
     *
     * 【Europe PMC】
     * 1. 文章详情页 - 主标题
     * 2. 搜索结果页 - 论文标题列表
     * 3. 文章详情页 - Similar articles 论文标题
     *
     * 【Semantic Scholar】
     * 1. 搜索结果页 - 论文标题列表
     * 2. 文章详情页 - 主标题
     * 3. 文章详情页 - Citations 论文标题
     * 4. 文章详情页 - References 论文标题
     * 5. 个人主页 - 论文标题列表
     *
     * 【Google Scholar】
     * 1. 搜索结果页 - 论文标题列表
     *
     * 【摘要翻译】可选功能
     * - PubMed、Europe PMC 文章详情页的摘要
     * - 默认关闭，需要在 CONFIG 中设置 translateAbstract: true 启用
     * - 翻译结果显示在摘要下方，带有独立的样式区块
     * - 可单独配置摘要翻译提供商
     *
     * 【翻译样式】
     * - 标题翻译：斜体显示（font-style: italic）、透明度 60%（opacity: 0.6）
     * - 摘要翻译：独立区块显示，带有浅色背景和左侧边框
     * - 继承父元素颜色
     * - 位于原文下方，自动换行
     *
     * 【智能特性】
     * - 自动检测语言，跳过中文内容
     * - 防止重复翻译
     * - 支持动态加载内容（MutationObserver）
     * - 多层防护机制确保翻译质量
     */

    // ╔══════════════════════════════════════════════════════════════════════════════╗
    // ║                          配置区域（从这里开始修改）                          ║
    // ╚══════════════════════════════════════════════════════════════════════════════╝
    //
    // [!] 提示：如果你不懂代码，只需要：
    //     1. 保持默认设置，无需修改任何内容
    //     2. 如果想启用摘要翻译，把 translateAbstract 改成 true
    //     3. 如果想用大模型，填写 apiKey 并修改 titleProvider
    //
    const CONFIG = {
        // ========== 翻译提供商设置 ==========

        // 【标题翻译提供商】
        // 免费：'google', 'microsoft'
        // 付费：'deepl', 'niutrans'
        // 大模型：'openai', 'gemini', 'openrouter', 'lmrouter', 'deepseek', 'siliconflow'
        titleProvider: 'microsoft',

        // 【摘要翻译开关】
        translateAbstract: false,

        // 【摘要翻译提供商】留空则使用 titleProvider
        abstractProvider: '',

        // ========== 翻译服务 API 配置 ==========

        google: {},
        microsoft: {},

        // DeepL 翻译：https://www.deepl.com/pro-api
        deepl: {
            apiKey: '', // 每月 50 万字符免费额度
            useFreeApi: true, // true = 免费版，false = 付费版
        },

        // 小牛翻译：https://niutrans.com/documents/contents/trans_text
        niutrans: {
            apiKey: '',// + 每日 100 积分，文本翻译：1 积分/2000 字符
        },

        // ========== 大模型 API 配置 ==========

        // OpenAI：https://platform.openai.com/
        openai: {
            apiKey: '',
            model: 'gpt-5-mini',
            temperature: 0.3,
        },

        // Google AI Studio (Gemini)：https://aistudio.google.com/
        gemini: {
            apiKey: '',
            model: 'gemini-2.5-flash',
            temperature: 0.3,
        },

        // OpenRouter：https://openrouter.ai/
        openrouter: {
            apiKey: '',
            model: 'openai/gpt-5-mini',
            temperature: 0.3,
        },

        // LMRouter：https://lmrouter.com/
        lmrouter: {
            apiKey: '',
            model: 'deepseek/deepseek-v3.2-exp',
            temperature: 0.3,
        },

        // DeepSeek：https://platform.deepseek.com/
        deepseek: {
            apiKey: '',
            model: 'deepseek-chat',
            temperature: 1.3,
        },

        // 硅基流动：https://siliconflow.cn/
        siliconflow: {
            apiKey: '',
            model: 'deepseek-ai/DeepSeek-V3.2-Exp',
            temperature: 0.3,
        },

        // ========== 并发和速率控制 ==========

        maxConcurrent: 2,
        requestDelay: 500,

        // ========== 翻译设置 ==========

        targetLanguage: 'zh-CN',
        translationStyle: '简体中文',

        // ========== 高级配置：大模型 Prompt ==========
        
        // 【System Prompt】定义模型的角色和行为
        // 提示：可以根据翻译需求自定义，比如：
        // - 更专业的医学术语翻译
        // - 保留特定格式
        // - 添加领域知识
        llmSystemPrompt: 'You are a professional medical and biomedical academic translation assistant. Translate English text into Simplified Chinese with precision, maintaining scientific rigor and professional terminology. Output ONLY the translation result without any explanations or additional content.',
        
        // 【User Prompt】翻译指令模板
        // 提示：{text} 会被替换为实际要翻译的文本
        // 可以添加额外要求，比如：
        // - 'Translate and explain technical terms: {text}'
        // - 'Translate concisely: {text}'
        llmUserPrompt: 'Translate the following English text into Simplified Chinese:\n\n{text}',
    };

    // ╔══════════════════════════════════════════════════════════════════════════════╗
    // ║                      以下不要修改，除非你明确知道你在做什么！                ║
    // ╚══════════════════════════════════════════════════════════════════════════════╝
    // ╔══════════════════════════════════════════════════════════════════════════════╗
    // ║                              工具函数 | Utilities                            ║
    // ╚══════════════════════════════════════════════════════════════════════════════╝

    /**
     * 注入全局样式
     */
    function injectStyles() {
        if (document.getElementById('translation-global-styles')) {
            return; // 已注入，避免重复
        }

        const style = document.createElement('style');
        style.id = 'translation-global-styles';
        style.textContent = `
            /* 翻译加载动画 */
            @keyframes translation-pulse {
                0%, 100% { opacity: 0.4; }
                50% { opacity: 0.8; }
            }
            .translation-loading, .abstract-translation-loading {
                animation: translation-pulse 1.5s ease-in-out infinite;
            }
            
            /* 翻译文本样式 */
            .translation-zh {
                display: block;
                margin-top: 4px;
                line-height: 1.4;
                font-style: italic;
                opacity: 0.6;
                font-weight: normal;
            }
            
            /* 摘要翻译容器样式 */
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
     * 实现并发控制和延迟控制，避免触发 API 速率限制
     * 策略：每个渠道先测试一个请求，成功后再开启并发
     * 
     * @class TranslationQueue
     * @description 管理翻译请求的队列，控制并发数量和请求间隔
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
            // 填满所有可用的并发槽位
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

                // 立即执行任务（不阻塞循环）
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

                        // 添加延迟后继续处理队列
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

    // 创建翻译队列实例
    const translationQueue = new TranslationQueue(CONFIG.maxConcurrent, CONFIG.requestDelay);

    // 失败计数器（分离标题和摘要）
    const failureCount = {
        title: {},    // 标题翻译失败计数：{ provider: count }
        abstract: {}  // 摘要翻译失败计数：{ provider: count }
    };
    const MAX_FAILURES = 3;
    // 停止标志（分离标题和摘要）
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
     * @param {string} text - 要检测的文本
     * @returns {boolean} 如果中文字符占比超过 50%，返回 true
     */
    function isChinese(text) {
        if (!text || text.trim().length === 0) return false;

        const chineseRegex = /[\u4e00-\u9fa5]/g;
        const chineseChars = text.match(chineseRegex);
        if (!chineseChars) return false;

        // 如果中文字符占比超过 50%，认为是中文文本
        const chineseRatio = chineseChars.length / text.length;
        return chineseRatio > 0.5;
    }

    /**
     * 调用 Google 翻译（免费）
     */
    function translateWithGoogle(text) {
        return new Promise((resolve, reject) => {
            const url = `https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=zh-CN&dt=t&q=${encodeURIComponent(text)}`;

            GM_xmlhttpRequest({
                method: 'GET',
                url: url,
                headers: {
                    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
                },
                onload: function (response) {
                    try {
                        if (response.status !== 200) {
                            reject(`Google 翻译请求失败：HTTP ${response.status}`);
                            return;
                        }

                        const result = JSON.parse(response.responseText);
                        if (result && result[0]) {
                            let translation = '';
                            result[0].forEach(item => {
                                if (item[0]) {
                                    translation += item[0];
                                }
                            });
                            resolve(translation.trim());
                        } else {
                            reject('Google 翻译返回格式错误');
                        }
                    } catch (e) {
                        reject(`Google 翻译解析失败：${e.message}`);
                    }
                },
                onerror: function (error) {
                    reject('Google 翻译网络请求失败：' + error);
                }
            });
        });
    }

    /**
     * 调用 Microsoft 翻译（免费）
     * 使用 Microsoft Edge 翻译接口
     */
    function translateWithMicrosoft(text) {
        return new Promise((resolve, reject) => {
            // 第一步：获取授权令牌
            GM_xmlhttpRequest({
                method: 'GET',
                url: 'https://edge.microsoft.com/translate/auth',
                onload: function (authResponse) {
                    try {
                        if (authResponse.status !== 200) {
                            reject(`Microsoft 授权失败：HTTP ${authResponse.status}`);
                            return;
                        }

                        const authToken = authResponse.responseText;

                        // 第二步：使用授权令牌进行翻译
                        GM_xmlhttpRequest({
                            method: 'POST',
                            url: 'https://api.cognitive.microsofttranslator.com/translate?api-version=3.0&to=zh-Hans&from=en',
                            headers: {
                                'Content-Type': 'application/json',
                                'Authorization': `Bearer ${authToken}`
                            },
                            data: JSON.stringify([{ text: text }]),
                            onload: function (translateResponse) {
                                try {
                                    if (translateResponse.status !== 200) {
                                        reject(`Microsoft 翻译请求失败：HTTP ${translateResponse.status}`);
                                        return;
                                    }

                                    const result = JSON.parse(translateResponse.responseText);
                                    if (result && result[0] && result[0].translations && result[0].translations[0]) {
                                        const translation = result[0].translations[0].text.trim();
                                        resolve(translation);
                                    } else {
                                        reject('Microsoft 翻译返回格式错误');
                                    }
                                } catch (e) {
                                    reject(`Microsoft 翻译解析失败：${e.message}`);
                                }
                            },
                            onerror: function (error) {
                                reject('Microsoft 翻译请求失败：' + error);
                            }
                        });
                    } catch (e) {
                        reject(`Microsoft 授权解析失败：${e.message}`);
                    }
                },
                onerror: function (error) {
                    reject('Microsoft 授权请求失败：' + error);
                }
            });
        });
    }

    /**
     * 调用 DeepL 翻译（需要 API Key）
     */
    function translateWithDeepL(text) {
        return new Promise((resolve, reject) => {
            if (!CONFIG.deepl.apiKey) {
                reject('DeepL API Key 未配置');
                return;
            }

            const baseUrl = CONFIG.deepl.useFreeApi
                ? 'https://api-free.deepl.com/v2/translate'
                : 'https://api.deepl.com/v2/translate';

            const params = new URLSearchParams({
                text: text,
                target_lang: 'ZH',
                auth_key: CONFIG.deepl.apiKey
            });

            GM_xmlhttpRequest({
                method: 'POST',
                url: baseUrl,
                headers: {
                    'Content-Type': 'application/x-www-form-urlencoded'
                },
                data: params.toString(),
                onload: function (response) {
                    try {
                        const result = JSON.parse(response.responseText);
                        if (result.translations && result.translations[0]) {
                            resolve(result.translations[0].text);
                        } else {
                            reject('DeepL 翻译响应格式错误');
                        }
                    } catch (e) {
                        reject('DeepL 翻译解析失败：' + e.message);
                    }
                },
                onerror: function (error) {
                    reject('DeepL 翻译网络请求失败：' + error);
                }
            });
        });
    }

    /**
     * 调用小牛翻译（需要 API Key）
     */
    function translateWithNiutrans(text) {
        return new Promise((resolve, reject) => {
            if (!CONFIG.niutrans.apiKey) {
                reject('小牛翻译 API Key 未配置');
                return;
            }

            GM_xmlhttpRequest({
                method: 'POST',
                url: 'https://api.niutrans.com/NiuTransServer/translation',
                headers: {
                    'Content-Type': 'application/json'
                },
                data: JSON.stringify({
                    src_text: text,
                    from: 'en',
                    to: 'zh',
                    apikey: CONFIG.niutrans.apiKey
                }),
                onload: function (response) {
                    try {
                        if (response.status !== 200) {
                            reject(`小牛翻译请求失败：HTTP ${response.status}`);
                            return;
                        }

                        const result = JSON.parse(response.responseText);
                        if (result.tgt_text) {
                            resolve(result.tgt_text.trim());
                        } else if (result.error_msg) {
                            reject(`小牛翻译错误：${result.error_msg}`);
                        } else {
                            reject('小牛翻译返回格式错误');
                        }
                    } catch (e) {
                        reject(`小牛翻译解析失败：${e.message}`);
                    }
                },
                onerror: function (error) {
                    reject('小牛翻译网络请求失败：' + error);
                }
            });
        });
    }



    /**
     * 调用大模型翻译（通用函数）
     * 
     * @description 支持所有 OpenAI Chat Completions API 格式的服务
     * @param {string} text - 要翻译的文本
     * @param {string} provider - 服务商名称
     * @returns {Promise<string>} 翻译结果
     */
    function translateWithLLM(text, provider) {
        return new Promise((resolve, reject) => {
            const config = CONFIG[provider];

            if (!config || !config.apiKey) {
                reject(`${provider} API Key 未配置`);
                return;
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
                reject(`未知的服务商或 baseURL 未配置：${provider}`);
                return;
            }

            // 使用配置的 prompt，支持 {text} 占位符
            const systemPrompt = CONFIG.llmSystemPrompt;
            const userPromptTemplate = CONFIG.llmUserPrompt;
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

            GM_xmlhttpRequest({
                method: 'POST',
                url: `${baseURL}/chat/completions`,
                headers: {
                    'Content-Type': 'application/json',
                    'Authorization': `Bearer ${config.apiKey}`
                },
                data: JSON.stringify({
                    model: config.model,
                    messages: messages,
                    temperature: config.temperature || 0.3
                }),
                onload: function (response) {
                    try {
                        if (response.status !== 200) {
                            reject(`${provider} 翻译请求失败：HTTP ${response.status}`);
                            return;
                        }

                        const result = JSON.parse(response.responseText);
                        if (result.choices && result.choices[0] && result.choices[0].message) {
                            const translation = result.choices[0].message.content.trim();
                            resolve(translation);
                        } else {
                            reject(`${provider} 翻译返回格式错误`);
                        }
                    } catch (e) {
                        reject(`${provider} 翻译解析失败：${e.message}`);
                    }
                },
                onerror: function (error) {
                    reject(`${provider} 翻译网络请求失败：` + error);
                }
            });
        });
    }

    /**
     * 根据配置选择翻译 API
     * @param {string} text - 要翻译的文本
     * @param {string} type - 翻译类型：'title' 或 'abstract'
     */
    function translate(text, type = 'title') {
        // 检查对应类型的翻译是否已停止
        if (scriptStopped[type]) {
            return Promise.reject(`${type === 'title' ? '标题' : '摘要'}翻译已因连续失败而停止，请检查配置`);
        }

        // 根据类型选择提供商
        let provider;
        if (type === 'abstract' && CONFIG.abstractProvider) {
            provider = CONFIG.abstractProvider;
        } else {
            provider = CONFIG.titleProvider;
        }

        // 控制台日志：开始翻译
        const typeText = type === 'abstract' ? '摘要' : '标题';
        const preview = text.length > 50 ? text.substring(0, 50) + '...' : text;
        console.log(`%c[翻译${typeText}] %c使用 ${provider} 翻译：%c${preview}`,
            'color: #4CAF50; font-weight: bold',
            'color: #2196F3',
            'color: #666');

        // 选择对应的翻译函数
        let translateFunc;

        const llmProviders = ['openai', 'gemini', 'openrouter', 'lmrouter', 'deepseek', 'siliconflow'];

        if (llmProviders.includes(provider)) {
            // 使用通用大模型翻译函数
            translateFunc = () => translateWithLLM(text, provider);
        } else {
            // 使用专用翻译函数
            switch (provider) {
                case 'google':
                    translateFunc = () => translateWithGoogle(text);
                    break;
                case 'microsoft':
                    translateFunc = () => translateWithMicrosoft(text);
                    break;
                case 'deepl':
                    translateFunc = () => translateWithDeepL(text);
                    break;
                case 'niutrans':
                    translateFunc = () => translateWithNiutrans(text);
                    break;
                default:
                    console.error(`%c[翻译错误] 未知的 API 提供商：${provider}`, 'color: #f44336; font-weight: bold');
                    return Promise.reject(`未知的 API 提供商：${provider}`);
            }
        }

        // 通过队列管理器执行翻译，并记录结果
        return translationQueue.add(translateFunc, type, provider)
            .then(result => {
                // 重置对应渠道和类型的失败计数
                if (!failureCount[type][provider]) {
                    failureCount[type][provider] = 0;
                }
                failureCount[type][provider] = 0;

                console.log(`%c[翻译成功] %c${result}`,
                    'color: #4CAF50; font-weight: bold',
                    'color: #333');
                return result;
            })
            .catch(error => {
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

                // 检查是否达到最大失败次数
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
                    alert(`⚠️ PubMed 翻译脚本错误\n\n${message}\n\n✓ ${typeText}翻译已停止\n${type === 'title' ? '✓ 摘要翻译继续运行' : '✓ 标题翻译继续运行'}\n\n可能原因：\n1. API Key 配置错误\n2. 网络连接问题\n3. API 额度不足\n4. 服务商接口异常`);
                }

                throw error;
            });
    }

    /**
     * 默认的文本获取函数
     * 克隆元素并移除已存在的翻译，返回纯文本
     */
    function defaultGetText(element) {
        const clone = element.cloneNode(true);
        const existingTranslation = clone.querySelector('.translation-zh');
        if (existingTranslation) existingTranslation.remove();
        return clone.textContent.trim();
    }

    /**
     * 默认的标题翻译创建函数
     * 在标题元素内部添加翻译文本
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
     * 摘要翻译与标题翻译的区别：
     * 1. 翻译文本较长，需要分段处理
     * 2. 翻译结果显示在摘要下方，作为独立的翻译区块
     * 3. 需要保留原文格式（段落、斜体等）
     */
    async function addAbstractTranslation(abstractElement, getTextFunc) {
        // 检查配置开关
        if (!CONFIG.translateAbstract) {
            return;
        }

        // 检查摘要翻译是否已停止
        if (scriptStopped.abstract) {
            return;
        }

        // 检查是否已翻译或正在翻译
        if (abstractElement.dataset.translated === 'true' || abstractElement.dataset.translating === 'true') {
            return;
        }

        // 检查是否已存在翻译
        if (abstractElement.querySelector('.abstract-translation-container') ||
            abstractElement.parentElement.querySelector('.abstract-translation-container')) {
            abstractElement.dataset.translated = 'true';
            return;
        }

        const originalText = getTextFunc(abstractElement);
        if (!originalText || originalText.trim().length === 0) {
            return;
        }

        // 检测是否是中文
        if (isChinese(originalText)) {
            abstractElement.dataset.translated = 'true';
            return;
        }

        // 创建加载动画
        const loadingDiv = document.createElement('div');
        loadingDiv.className = 'abstract-translation-loading';
        loadingDiv.style.cssText = 'margin-top: 8px; font-style: italic; opacity: 0.6;';
        loadingDiv.textContent = '正在翻译摘要...';

        // 插入加载动画
        abstractElement.parentElement.insertBefore(loadingDiv, abstractElement.nextSibling);

        try {
            // 标记为正在翻译
            abstractElement.dataset.translating = 'true';

            // 调用翻译 API（使用摘要专用提供商）
            const translation = await translate(originalText, 'abstract');

            // 移除加载动画
            if (loadingDiv && loadingDiv.parentElement) {
                loadingDiv.remove();
            }

            // 再次检查是否已存在翻译
            if (abstractElement.querySelector('.abstract-translation-container') ||
                abstractElement.parentElement.querySelector('.abstract-translation-container')) {
                abstractElement.dataset.translated = 'true';
                abstractElement.dataset.translating = 'false';
                return;
            }

            // 创建折叠容器
            const collapseContainer = document.createElement('div');
            collapseContainer.className = 'abstract-translation-container';
            collapseContainer.style.display = 'none'; // 初始隐藏整个容器

            // 创建折叠按钮
            const toggleButton = document.createElement('button');
            toggleButton.className = 'abstract-translation-toggle';
            toggleButton.textContent = '▶ 显示中文翻译';

            // 创建翻译内容容器
            const translationDiv = document.createElement('div');
            translationDiv.className = 'abstract-translation-zh';
            translationDiv.style.display = 'none'; // 初始隐藏
            translationDiv.textContent = translation; // 直接使用翻译结果，不做任何处理

            // 添加点击事件
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

            // 组装元素
            collapseContainer.appendChild(toggleButton);
            collapseContainer.appendChild(translationDiv);

            // 插入到摘要后面
            abstractElement.parentElement.insertBefore(collapseContainer, abstractElement.nextSibling);

            // 翻译完成后再显示容器（使用短暂延迟确保 DOM 更新完成）
            setTimeout(() => {
                collapseContainer.style.display = 'block';
            }, 10);

            // 标记为已翻译
            abstractElement.dataset.translated = 'true';
            abstractElement.dataset.translating = 'false';
        } catch (error) {
            // 移除加载动画
            if (loadingDiv && loadingDiv.parentElement) {
                loadingDiv.remove();
            }

            console.error(`%c[摘要翻译失败] %c${error}`,
                'color: #f44336; font-weight: bold',
                'color: #f44336');
            abstractElement.dataset.translating = 'false';
        }
    }

    /**
     * 为标题元素添加翻译
     */
    async function addTranslation(titleElement, getTextFunc, createTranslationFunc) {
        // 检查标题翻译是否已停止
        if (scriptStopped.title) {
            return;
        }

        // 检查是否已翻译或正在翻译
        if (titleElement.dataset.translated === 'true' || titleElement.dataset.translating === 'true') {
            return;
        }

        // 检查是否已经存在翻译元素（防止重复翻译）
        // 检查标题元素内部和父元素
        const existingTranslation = titleElement.querySelector('.translation-zh') ||
            titleElement.parentElement?.querySelector('.translation-zh');
        if (existingTranslation) {
            titleElement.dataset.translated = 'true';
            return;
        }

        const originalText = getTextFunc(titleElement);
        if (!originalText || originalText.trim().length === 0) {
            return;
        }

        // 检测是否是中文，如果是则不翻译
        if (isChinese(originalText)) {
            titleElement.dataset.translated = 'true';
            return;
        }

        // 创建加载动画
        const loadingElement = document.createElement('span');
        loadingElement.className = 'translation-loading translation-zh';
        loadingElement.textContent = '翻译中...';

        // 将加载动画插入到标题内部（与翻译结果位置一致）
        titleElement.appendChild(loadingElement);

        try {
            // 标记为正在翻译
            titleElement.dataset.translating = 'true';

            // 调用翻译 API（使用标题提供商）
            const translation = await translate(originalText, 'title');

            // 移除加载动画
            if (loadingElement && loadingElement.parentElement) {
                loadingElement.remove();
            }

            // 再次检查是否已存在翻译（防止并发问题）
            const checkExisting = titleElement.querySelector('.translation-zh') ||
                titleElement.parentElement?.querySelector('.translation-zh');
            if (checkExisting) {
                titleElement.dataset.translated = 'true';
                titleElement.dataset.translating = 'false';
                return;
            }

            // 创建并插入翻译元素
            createTranslationFunc(titleElement, translation);

            // 标记为已翻译
            titleElement.dataset.translated = 'true';
            titleElement.dataset.translating = 'false';
        } catch (error) {
            // 移除加载动画
            if (loadingElement && loadingElement.parentElement) {
                loadingElement.remove();
            }

            console.error(`%c[标题翻译失败] %c${error}`,
                'color: #f44336; font-weight: bold',
                'color: #f44336');
            titleElement.dataset.translating = 'false';

            // 可选：显示错误提示
            // createTranslationFunc(titleElement, `[翻译失败：${error}]`);
        }
    }

    // ╔══════════════════════════════════════════════════════════════════════════════╗
    // ║                        网站特定处理 | Site Processors                        ║
    // ╚══════════════════════════════════════════════════════════════════════════════╝

    /**
     * PubMed 处理器
     * 
     * @description 处理 PubMed 网站的论文标题和摘要翻译
     * @website https://pubmed.ncbi.nlm.nih.gov/
     * @supports
     *   - 主页 (Home): Trending Articles
     *   - 搜索结果页 (Search): 论文标题列表
     *   - 文章详情页 (Detail): 主标题、Similar articles、Cited by、摘要
     */
    async function processPubMed() {
        // 收集所有需要翻译的标题元素
        const titleElements = [];

        // 1. 主页 - Trending Articles 区域的论文标题
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

        // 2. 搜索结果页 + Similar articles + Cited by
        const docsumTitles = document.querySelectorAll('.docsum-title');
        docsumTitles.forEach(titleElement => {
            titleElements.push({
                element: titleElement,
                getText: defaultGetText,
                createTranslation: defaultCreateTranslation
            });
        });

        // 3. 文章详情页 - 主标题
        const detailTitleSelectors = [
            'h1.heading-title',
            '.heading-title',
            'h1[class*="heading"]',
            'main h1',
            'article h1',
        ];

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

        // 翻译所有标题（并发）
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

    /**
     * Europe PMC 处理
     * 支持的页面类型：
     * - 文章详情页 (Detail): 主标题、Similar articles
     * - 搜索结果页 (Search): 论文标题列表（与 Similar articles 使用相同选择器）
     * 
     * 注意：Europe PMC 的搜索结果页和 Similar articles 使用相同的 HTML 结构，
     * 因此使用统一的选择器 h3.citation-title a 即可覆盖两种情况
     */
    async function processEuropePMC() {
        // 1. 文章详情页 - 主标题
        // 选择器：h1#article--current--title, h1.article-metadata-title
        // 示例 HTML：
        // <h1 id="article--current--title" class="article-metadata-title">TRIM13 prevents...</h1>
        const detailTitleSelectors = [
            'h1#article--current--title',
            'h1.article-metadata-title',
            'h1[id*="article"][id*="title"]',
        ];

        let detailTitle = null;
        for (const selector of detailTitleSelectors) {
            detailTitle = document.querySelector(selector);
            if (detailTitle && detailTitle.textContent.trim().length > 0) {
                break;
            }
            detailTitle = null;
        }

        if (detailTitle) {
            addTranslation(detailTitle, defaultGetText, defaultCreateTranslation);
        }

        // 2. 搜索结果页 + Similar articles - 统一使用 h3.citation-title a
        const titleElements = [];

        const citationTitles = document.querySelectorAll('h3.citation-title a');
        citationTitles.forEach(titleElement => {
            titleElements.push({
                element: titleElement,
                getText: defaultGetText,
                createTranslation: defaultCreateTranslation
            });
        });

        // 翻译所有标题
        await Promise.all(titleElements.map(item =>
            addTranslation(item.element, item.getText, item.createTranslation)
        ));

        // 标题翻译完成后，再翻译摘要
        if (CONFIG.translateAbstract) {
            const abstractSelectors = [
                'div#article--abstract--content.abstract',
                'div.abstract-content#eng-abstract',
            ];

            let abstractElement = null;
            for (const selector of abstractSelectors) {
                abstractElement = document.querySelector(selector);
                if (abstractElement && abstractElement.textContent.trim().length > 0) {
                    break;
                }
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

    // ==================== 主函数 ====================

    /**
     * Semantic Scholar 处理
     * 支持的页面类型：
     * - 搜索结果页 (Search): 论文标题列表
     * - 文章详情页 (Detail): 主标题、Citations、References
     * - 个人主页 (Profile): 论文标题列表
     * 
     * 注意：除了详情页主标题外，其他所有标题都使用 .cl-paper-title 类
     */
    async function processSemanticScholar() {
        // 1. 文章详情页 - 主标题
        // 选择器：h1[data-test-id="paper-detail-title"]
        // 示例 HTML：
        // <h1 data-test-id="paper-detail-title">Trim and Fill: A Simple Funnel...</h1>
        const detailTitle = document.querySelector('h1[data-test-id="paper-detail-title"]');
        if (detailTitle && detailTitle.textContent.trim().length > 0) {
            addTranslation(detailTitle, defaultGetText, defaultCreateTranslation);
        }

        // 2. 搜索结果页 + Citations + References + 个人主页
        const titleElements = [];

        const paperTitles = document.querySelectorAll('.cl-paper-title');
        paperTitles.forEach(titleElement => {
            titleElements.push({
                element: titleElement,
                getText: defaultGetText,
                createTranslation: defaultCreateTranslation
            });
        });

        // 翻译所有标题
        await Promise.all(titleElements.map(item =>
            addTranslation(item.element, item.getText, item.createTranslation)
        ));
    }

    /**
     * Google Scholar 处理
     * 支持的页面类型：
     * - 搜索结果页 (Search): 论文标题列表
     * 
     * 注意：Google Scholar 只有搜索功能，没有详情页
     */
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

        // 翻译所有标题
        await Promise.all(titleElements.map(item =>
            addTranslation(item.element, item.getText, item.createTranslation)
        ));
    }

    /**
     * 根据当前网站选择对应的处理函数
     */
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

    /**
     * 验证配置的有效性
     * @returns {Object} { valid: boolean, errors: string[] }
     */
    function validateConfig() {
        const errors = [];

        // 支持的翻译提供商列表
        const supportedProviders = [
            'google', 'microsoft',
            'deepl', 'niutrans',
            'openai', 'gemini', 'openrouter', 'lmrouter',
            'deepseek', 'siliconflow'
        ];

        const apiKeyProviders = [
            'deepl', 'niutrans',
            'openai', 'gemini', 'openrouter', 'lmrouter',
            'deepseek', 'siliconflow'
        ];

        // 验证标题提供商
        if (!supportedProviders.includes(CONFIG.titleProvider)) {
            errors.push(`未知的标题翻译提供商：${CONFIG.titleProvider}`);
        } else if (apiKeyProviders.includes(CONFIG.titleProvider)) {
            const config = CONFIG[CONFIG.titleProvider];
            if (!config || !config.apiKey || config.apiKey.trim() === '') {
                errors.push(`${CONFIG.titleProvider} 需要配置 API Key`);
            }
        }

        // 验证摘要提供商（如果配置了）
        if (CONFIG.abstractProvider && CONFIG.abstractProvider.trim() !== '') {
            if (!supportedProviders.includes(CONFIG.abstractProvider)) {
                errors.push(`未知的摘要翻译提供商：${CONFIG.abstractProvider}`);
            } else if (apiKeyProviders.includes(CONFIG.abstractProvider)) {
                const config = CONFIG[CONFIG.abstractProvider];
                if (!config || !config.apiKey || config.apiKey.trim() === '') {
                    errors.push(`${CONFIG.abstractProvider} 需要配置 API Key`);
                }
            }
        }

        // 验证并发和延迟配置
        if (CONFIG.maxConcurrent < 1) {
            errors.push('maxConcurrent 必须大于等于 1');
        }
        if (CONFIG.requestDelay < 0) {
            errors.push('requestDelay 必须大于等于 0');
        }

        return {
            valid: errors.length === 0,
            errors: errors
        };
    }

    /**
     * 使用 MutationObserver 监听 DOM 变化
     * 使用防抖机制避免频繁触发
     */
    function observeChanges() {
        let timeoutId = null;

        const observer = new MutationObserver((mutations) => {
            // 清除之前的定时器
            if (timeoutId) {
                clearTimeout(timeoutId);
            }

            // 延迟执行，避免频繁触发（防抖）
            timeoutId = setTimeout(() => {
                processCurrentSite();
                timeoutId = null;
            }, 500);
        });

        observer.observe(document.body, {
            childList: true,
            subtree: true
        });
    }

    // ==================== 初始化 ====================

    // 输出启动信息
    console.log('%cPubMed 文献标题翻译 v1.0', 'color: #4CAF50; font-size: 16px; font-weight: bold');
    console.log('%cPubMed Academic Title Translator', 'color: #2196F3; font-size: 12px');
    console.log('%cBuild by Miao and Claude Sonnet 4.5 with ♥', 'color: #FF5722; font-size: 12px');
    console.log('');

    // 验证配置
    const validation = validateConfig();
    if (!validation.valid) {
        console.error('%c[配置错误] 请检查以下问题：', 'color: #f44336; font-weight: bold; font-size: 14px');
        validation.errors.forEach(error => {
            console.error(`  ❌ ${error}`);
        });
        console.error('\n%c脚本无法启动，请修正配置后刷新页面。', 'color: #f44336; font-weight: bold');
        alert(`PubMed 文献标题翻译配置错误：\n\n${validation.errors.join('\n')}\n\n请打开脚本编辑器修正配置后刷新页面。`);
        return; // 终止脚本执行
    }

    // 注入全局样式
    injectStyles();

    // 输出配置信息
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
    console.log(`  并发数量：${CONFIG.maxConcurrent}`);
    console.log(`  请求延迟：${CONFIG.requestDelay}ms`);

    const allLlmProviders = ['openai', 'gemini', 'openrouter', 'lmrouter', 'deepseek', 'siliconflow'];
    const usedProviders = [CONFIG.titleProvider, CONFIG.abstractProvider].filter(p => allLlmProviders.includes(p));

    if (usedProviders.length > 0) {
        usedProviders.forEach(provider => {
            const config = CONFIG[provider];
            if (config && config.model) {
                console.log(`  ${providerNameMap[provider]} 模型：${config.model}`);
            }
        });
    }
    console.log('');

    // 页面加载完成后执行
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', () => {
            processCurrentSite();
            observeChanges();
        });
    } else {
        processCurrentSite();
        observeChanges();
    }

    console.log('%c[脚本已启动] 正在监听页面变化...', 'color: #4CAF50; font-weight: bold');

})();
