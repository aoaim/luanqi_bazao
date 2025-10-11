# PubMed 文献标题翻译

<div align="center">

![PubMed Translator](icons/pubmed_icon.png)

**自动翻译 PubMed、Europe PMC、Semantic Scholar、Google Scholar 上的论文标题和摘要为中文**

[![Version](https://img.shields.io/badge/version-1.0-blue.svg)](https://github.com/aoaim/luanqi_bazao)
[![License](https://img.shields.io/badge/license-GPLv3-blue.svg)](LICENSE)
[![Chrome](https://img.shields.io/badge/Chrome-Extension-orange.svg)](https://www.google.com/chrome/)
[![Code with AI](https://img.shields.io/badge/Code%20with-AI-blue)](https://github.com/aoaim/luanqi_bazao)

</div>

---

## 📖 简介

PubMed 文献标题翻译是一款专为医学科研人员设计的 Chrome 浏览器扩展，能够在查询文献时自动将英文的论文标题和摘要翻译成简体中文，大幅提升文献查阅效率。

### ✨ 主要特性

- 🚀 **自动翻译**：无需手动操作，打开页面即可自动翻译
- 🌐 **多网站支持**：支持 PubMed、Europe PMC、Semantic Scholar、Google Scholar 主流学术搜索引擎
- 🔄 **多翻译引擎**：内置多种翻译服务，包括免费和付费选项
- 🤖 **AI 大模型支持**：支持 OpenAI、Google AI Studio (Gemini)、DeepSeek 等大语言模型
- 💾 **智能缓存**：翻译结果本地缓存，避免重复翻译
- ⚙️ **灵活配置**：可视化设置界面，轻松切换翻译服务

---

## 🎯 支持的网站

### PubMed
- ✅ 主页 Trending Articles
- ✅ 搜索结果页论文标题
- ✅ 文章详情页主标题
- ✅ Similar articles 相关文献
- ✅ Cited by 引用文献
- ✅ 摘要翻译（可选）

### Europe PMC
- ✅ 文章详情页主标题
- ✅ 搜索结果页论文标题
- ✅ Similar articles 相关文献
- ✅ 摘要翻译（可选）

### Semantic Scholar
- ✅ 搜索结果页论文标题
- ✅ 文章详情页主标题
- ✅ Citations 引用文献
- ✅ References 参考文献
- ✅ 个人主页论文列表

### Google Scholar
- ✅ 搜索结果页论文标题

---

## 🚀 快速开始

### 安装方法

#### 方法一：Chrome 应用商店安装
> 待上架...

#### 方法二：开发者模式安装

1. **下载扩展文件**
   - 下载 `js/pubmed-translator-chrome` 路径的项目文件放到你喜欢的地方

2. **打开 Chrome 扩展管理页面**
   - 在地址栏输入：`chrome://extensions/`
   - 或点击：菜单 → 更多工具 → 扩展程序

3. **启用开发者模式**
   - 打开页面右上角的"开发者模式"开关

4. **加载扩展**
   - 点击"加载已解压的扩展程序"
   - 选择 `pubmed-translator-chrome` 文件夹

5. **完成安装**
   - 扩展图标会出现在浏览器工具栏
   - 首次使用建议先配置翻译服务

---

## ⚙️ 配置指南

### 打开设置页面

点击浏览器工具栏中的扩展图标，打开设置弹窗。

### 基础设置

#### 1. 选择翻译提供商

**免费服务（无需注册，开箱即用）**
- **Google 翻译**：稳定可靠，速度快，但中国大陆不可用
- **Microsoft 翻译**：稳定可靠，速度快（默认选项）

**付费服务（需要 API Key）**
- **DeepL 翻译**：翻译质量高，每月 50 万字符免费额度
- **小牛翻译**：国内服务，每日 100 积分免费额度

**大模型服务（需要 API Key）**
- **OpenAI**：GPT 系列模型，翻译准确度高
- **Google AI Studio (Gemini)**：使用 Gemini 模型，可通过 Google AI Studio 获取 API Key
- **OpenRouter**：大模型聚合平台
- **LMRouter**：大模型聚合平台
- **DeepSeek**：国产优秀大模型
- **硅基流动**：国内大模型推理平台

#### 2. 摘要翻译设置

- **启用摘要翻译**：勾选"翻译摘要"复选框
- **摘要翻译提供商**：可单独设置摘要翻译服务（默认与标题相同）

### API 配置

点击"API 配置"展开详细设置。请根据您选择的翻译服务，参考下表填写相应配置：

| 服务商 (Provider) | 配置项 (Options) | 获取地址 (Get API Key) | 备注 (Notes) |
| :--- | :--- | :--- | :--- |
| **DeepL** | `API Key`, `使用免费版 API` | [deepl.com](https://www.deepl.com/pro-api) | 免费额度每月 50 万字符 |
| **小牛翻译** | `API Key` | [niutrans.com](https://niutrans.com) | 注册后有免费额度 |
| **OpenAI** | `API Key`, `Model`, `Temperature` | [platform.openai.com](https://platform.openai.com) | |
| **Google AI Studio (Gemini)** | `API Key`, `Model`, `Temperature` | [aistudio.google.com](https://aistudio.google.com) | 使用 Google AI Studio 获取 API Key |
| **OpenRouter** | `API Key`, `Model`, `Temperature` | [openrouter.ai](https://openrouter.ai) | 大模型聚合平台 |
| **LMRouter** | `API Key`, `Model`, `Temperature` | [lmrouter.com](https://lmrouter.com) | 大模型聚合平台 |
| **DeepSeek** | `API Key`, `Model`, `Temperature` | [platform.deepseek.com](https://platform.deepseek.com) | |
| **硅基流动** | `API Key`, `Model`, `Temperature` | [siliconflow.cn](https://siliconflow.cn) | [通过此处注册](https://cloud.siliconflow.cn/i/W4xwMPJe)获得免费赠金 |

### 高级设置

- **最大并发数**：同时进行的翻译请求数量（默认：2）
- **请求延迟**：每个请求之间的延迟时间（毫秒，默认：500）
- **缓存设置**：
  - 启用缓存：避免重复翻译相同内容
  - 缓存时长：翻译结果保存天数（默认：7 天）

---

## 🔧 技术架构

### 项目结构

```
pubmed-translator-chrome/
├── manifest.json          # 扩展配置文件
├── background.js          # 后台服务 Worker
├── content.js             # 内容脚本（主要逻辑）
├── popup.html             # 设置页面 HTML
├── popup.css              # 设置页面样式
├── popup.js               # 设置页面逻辑
├── icons/                 # 图标资源
│   ├── pubmed_icon.svg
│   ├── pubmed_icon_16.png
│   ├── pubmed_icon_48.png
│   └── pubmed_icon_128.png
└── README.md              # 项目说明文档
```

### 核心功能模块

#### 1. 配置管理（Configuration）
- 使用 Chrome Storage API 持久化存储配置
- 支持配置导入/导出
- 配置变更实时同步

#### 2. 翻译引擎（Translation Engines）
- **免费翻译**：Google、Microsoft
- **付费翻译**：DeepL、小牛翻译
- **AI 大模型**：OpenAI、Google AI Studio (Gemini)、DeepSeek 等
- **统一接口**：所有翻译引擎实现相同的调用接口

#### 3. 队列管理（Queue Manager）
- **智能并发控制**：通过设置最大并发数，避免同时发起过多请求，减轻浏览器和服务器压力。
- **请求速率限制**：在每个翻译请求之间加入可配置的延迟，有效避免因请求频率过高而触发 API 服务商的速率限制。
- **先行测试策略**：每个翻译服务在首次使用时会先进行一次“测试”请求。如果成功，则完全开启并发处理后续任务；如果失败，则能快速定位问题，避免大量无效请求。

#### 4. 错误处理与恢复（Error Handling & Recovery）
- **失败计数与熔断**：为每个翻译服务（标题和摘要可独立配置）设置独立的失败计数器。当某个服务连续失败达到预设次数（默认为 3 次）后，系统将自动“熔断”，停止使用该服务进行新的翻译，并弹出提示。
- **任务隔离**：标题翻译和摘要翻译的失败处理是相互隔离的。例如，如果摘要翻译服务配置错误导致失败，只会停止摘要翻译，标题翻译功能将不受影响，反之亦然。
- **队列清理**：一旦某个服务被熔断，队列中所有等待该服务处理的任务将被立即清空，防止资源浪费和后续连锁错误。
- **用户通知**：在服务熔断时，会通过弹窗明确告知用户哪个环节出现问题，引导用户检查 API Key、网络连接或服务商配置，方便快速定位和解决问题。

#### 5. 缓存系统（Cache System）
- 本地存储：使用 Chrome Storage API
- 自动过期：可配置缓存时长
- 智能清理：自动清理过期缓存

#### 6. DOM 处理（DOM Processor）
- 元素选择器：针对不同网站的 CSS 选择器
- MutationObserver：监听页面动态变化
- 防重复翻译：标记已翻译元素

#### 7. 样式注入（Style Injection）
- 全局样式：翻译文本的统一样式
- 响应式设计：适配不同页面布局
- 动画效果：加载动画、折叠动画

---

## 🛡️ 隐私与安全

### 数据处理

- ✅ **本地处理**：所有配置和缓存数据仅存储在本地浏览器
- ✅ **不收集数据**：不向任何额外第三方服务器发送用户数据
- ✅ **API Key 安全**：API Key 仅存储在本地，不会上传
- ✅ **最小权限**：仅请求必要的浏览器权限

### 网络请求

本扩展会向以下服务发起网络请求（仅在使用相应翻译服务时）：

**免费翻译服务**
- `translate.googleapis.com` - Google 翻译
- `edge.microsoft.com` - Microsoft 认证
- `api.cognitive.microsofttranslator.com` - Microsoft 翻译

**付费翻译服务**
- `api-free.deepl.com` / `api.deepl.com` - DeepL 翻译
- `api.niutrans.com` - 小牛翻译

**AI 大模型服务**
- `api.openai.com` - OpenAI
- `generativelanguage.googleapis.com` - Google AI Studio (Gemini)
- `openrouter.ai` - OpenRouter
- `api.lmrouter.com` - LMRouter
- `platform.deepseek.com` - DeepSeek
- `api.siliconflow.cn` - 硅基流动

**重要提示**：使用翻译服务时，请务必阅读并遵守其服务条款和隐私政策。

---

## 🤝 参与贡献

我们热烈欢迎并感谢所有形式的贡献！如果您有兴趣参与，可以通过以下方式：

- **💡 提交功能建议**：如果您有好的想法，欢迎通过 [GitHub Issues](https://github.com/aoaim/luanqi_bazao/issues) 提交。
- **🐛 报告 Bug**：发现问题？请在 Issue 中详细描述复现步骤。
- **🛠️ 提交代码**：
  - 修复已知 Bug。
  - 增加对新的学术网站的支持。
  - 集成新的翻译引擎或 AI 大模型。
- **📖 完善文档**：改进 README 或其他说明文档。

在提交 Pull Request 之前，建议您先创建一个 Issue 来讨论您的想法。

---

## 🙏 致谢

- 感谢所有提供免费和付费 API 的翻译服务商。
- 感谢各大 AI 平台提供的强大模型支持。
- 感谢 VS Code 和 Github Copilot，以及 Copilot 背后强大的 Claude Sonnnet 4.5。

---

## 📝 更新日志

### v1.0 (2025-10-11)

**首次发布**
- ✨ 支持 PubMed、Europe PMC、Semantic Scholar、Google Scholar
- ✨ 集成 10+ 种翻译服务
- ✨ 支持标题和摘要翻译
- ✨ 智能缓存系统
- ✨ 可视化配置界面
- ✨ 并发控制和速率限制

---

## 📄 开源协议

本项目采用 [GPLv3](LICENSE) 协议开源。

---

## 📮 联系方式

如有问题或建议，请通过以下方式联系：

- 📧 GitHub Issues: [提交 Issue](https://github.com/aoaim/luanqi_bazao/issues)

---


Made with ❤️ by Miao and Claude Sonnet 4.5

</div>
