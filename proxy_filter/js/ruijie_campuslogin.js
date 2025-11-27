/**
 * Surge Script: 校园网自动登录 (Ruijie ePortal)
 * 参考实现: https://www.cnblogs.com/0x000001/p/18766279
 * 功能:
 *  - 自动检测重定向并完成锐捷认证登录
 *  - 支持通过参数传入 `username` 和 `password`
 *  - 可配置 `ssid`（目标无线名）和 `delay`（等待网络就绪秒数）
 *  - 在无法读取 SSID（如 macOS）时仍会尝试探测并登录
 *  - 登录成功/失败使用通知提醒，并包含简单的错误处理与重试友好延时
 * 为 HebMUer 编写，已在 HebMU 测试通过: 2025-11-23
 * Made by Gemini 3.0 Pro
 * Update: 2025-11-23  18:26
 */

const CHECK_URL_DOMAIN = 'http://www.baidu.com';
const CHECK_URL_IP = 'http://110.242.68.3';
const USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36 Edg/134.0.0.0';

const DEFAULT_CONFIG = {
    ssid: 'HebmuWlan',
    delay: 1
};

(async () => {
    log("========== 脚本启动 ==========");
    log("📝 开始解析配置参数...");
    const args = parseArguments($argument);
    
    if (!args.username || !args.password) {
        const errMsg = "❌ 配置缺失: 请在模块设置中填写账号和密码";
        log(errMsg);
        notify(errMsg);
        $done();
        return;
    }
    log(`✓ 配置已加载: 用户名=${args.username}`);

    const TARGET_SSID = args.ssid || DEFAULT_CONFIG.ssid;
    let delaySec = parseInt(args.delay) || DEFAULT_CONFIG.delay;
    if (delaySec < 1) delaySec = 1;
    log(`✓ 目标SSID: ${TARGET_SSID}, 延迟: ${delaySec}s`);

    // --- 1. 环境预检 ---
    log("🔍 开始环境预检...");
    let currentWifi = $network.wifi.ssid;
    log(`📡 当前Wi-Fi: ${currentWifi || "未检测到/有线网络"}`);
    const readyTimeout = parseInt(args.readyTimeout) || 20; // 额外等待获取 IP（macOS 冷启动常见）
    let hasIP = Boolean($network && $network.v4 && $network.v4.primaryAddress);

    for (let i = 0; i < readyTimeout && !hasIP; i++) {
        await sleep(1000);
        currentWifi = $network.wifi.ssid;
        hasIP = Boolean($network && $network.v4 && $network.v4.primaryAddress);
        if (currentWifi && currentWifi !== TARGET_SSID) {
            log(`⏭️ 非目标网络(${currentWifi})，跳过检测`);
            $done();
            return;
        }
        if (i === 0 || (i + 1) % 3 === 0) {
            log(`⏳ 等待网络就绪: SSID=${currentWifi || "null"}, hasIP=${hasIP}`);
        }
    }

    const logSSID = currentWifi ? currentWifi : "未知(macOS/有线)";
    log(`✓ 环境符合: ${logSSID}, hasIP=${hasIP}`);
    log(`⏳ 等待网络稳定 ${delaySec}s...`);
    
    await sleep(delaySec * 1000);
    log("✓ 等待完成，开始网络检测");

    try {
        // --- 2. 探测认证 (混合模式) ---
        log("========== 开始认证探测 ==========");
        
        let authInfo = null;
        const MAX_RETRIES = 5; // 最大重试次数
        
        for (let i = 1; i <= MAX_RETRIES; i++) {
            const result = await getAuthInfoHybrid();
            
            if (result.status === 'portal') {
                authInfo = result.data;
                break;
            } else if (result.status === 'online') {
                const msg = "✅ 网络已连通，无需认证";
                log(msg);
                if (currentWifi === TARGET_SSID) {
                    notify(msg);
                }
                $done();
                return;
            } else {
                // status === 'error'
                if (i < MAX_RETRIES) {
                    log(`⚠️ 第 ${i} 次检测失败或网络不可达，等待 3s 后重试...`);
                    await sleep(3000);
                } else {
                    log(`❌ 达到最大重试次数 (${MAX_RETRIES})，停止检测`);
                }
            }
        }

        if (!authInfo) {
            log("ℹ️ 未发现认证页面或网络不可用");
            $done();
            return;
        }

        log(`🔗 捕获认证地址: ${authInfo.baseUrl}`);
        notify(`🔗 检测到认证页面\n开始尝试登录...`);

        // --- 3. 执行登录 ---
        log("========== 开始登录流程 ==========");
        await login(args.username, args.password, authInfo);
        
    } catch (err) {
        const errMsg = `❌ 异常中止: ${err.message}`;
        log(errMsg);
        log(`错误堆栈: ${err.stack || '无'}`);
        notify(errMsg);
        $done();
    }
})();

// ================= 核心逻辑 =================

// 日志函数：仅打印到控制台
function log(message) {
    const time = new Date().toLocaleTimeString();
    console.log(`[CampusLogin ${time}] ${message}`);
}

// 通知函数：发送重要通知
function notify(message) {
    $notification.post("校园网连接助手", "", message);
    log(message); // 同时记录日志
}

async function getAuthInfoHybrid() {
    // 1. 尝试域名检测
    try {
        log(`🔍 方式1: 尝试域名检测 (${CHECK_URL_DOMAIN})...`);
        const result = await detect(CHECK_URL_DOMAIN);
        if (result) {
            log(`✓ 域名检测成功`);
            return { status: 'portal', data: result };
        }
        log(`✓ 域名检测完成，未发现认证页面`);
        return { status: 'online' };
    } catch (e) {
        log(`⚠️ 域名检测失败: ${e.message}`);
    }

    // 2. 域名失败，切换 IP 检测
    try {
        log(`🔍 方式2: 切换 IP 检测 (${CHECK_URL_IP})...`);
        const result = await detect(CHECK_URL_IP);
        if (result) {
            log(`✓ IP 检测成功`);
            return { status: 'portal', data: result };
        }
        log(`✓ IP 检测完成，未发现认证页面`);
        return { status: 'online' };
    } catch (e) {
        log(`⚠️ IP 检测失败: ${e.message}`);
    }

    log(`ℹ️ 所有检测方式均未发现认证页面 (网络可能不可达)`);
    return { status: 'error' };
}

function detect(url) {
    return new Promise((resolve, reject) => {
        log(`📡 发送HTTP请求: ${url}`);
        $httpClient.get({ 
            url: url, 
            headers: { 'User-Agent': USER_AGENT },
            timeout: 5 
        }, (error, response, data) => {
            if (error) {
                log(`❌ 请求失败: ${error}`);
                reject(new Error(error));
                return;
            }

            log(`✓ 收到响应: HTTP ${response.status}`);
            const loc = getHeader(response.headers, 'Location');
            if (loc) {
                const parsed = parsePortalUrl(loc);
                if (parsed) {
                    log(`✓ 通过重定向捕获认证: ${parsed.baseUrl}`);
                    resolve(parsed);
                    return;
                }
            }
            
            // 已联网
            if (response.status === 200 && data && data.includes('<title>百度一下，你就知道</title>')) {
                log("✓ 检测到百度首页，网络已通");
                resolve(null);
                return;
            }
            
            // 提取重定向
            log("🔍 分析响应内容，查找认证重定向...");
            const bodyMatch = parsePortalFromString(data);
            if (bodyMatch) {
                log(`✓ 发现认证重定向: ${bodyMatch.baseUrl}`);
                resolve(bodyMatch);
            } else {
                log(`ℹ️ 未找到认证重定向标记`);
                resolve(null);
            }
        });
    });
}

function login(username, password, authInfo) {
    return new Promise((resolve, reject) => {
        log(`📝 构建登录请求参数...`);
        const qsTwice = encodeURIComponent(encodeURIComponent(authInfo.queryString));
        const postBody = `userId=${username}&password=${password}&service=&queryString=${qsTwice}&operatorPwd=&operatorUserId=&validcode=&passwordEncrypt=false`;

        const loginUrl = `${authInfo.baseUrl}/eportal/InterFace.do?method=login`;
        const request = {
            url: loginUrl,
            headers: {
                "User-Agent": USER_AGENT,
                "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
                "Referer": `${authInfo.baseUrl}/eportal/index.jsp`,
                "Origin": authInfo.baseUrl
            },
            body: postBody,
            timeout: 15
        };

        log(`🚀 发起登录请求: ${loginUrl}`);
        log(`📤 用户名: ${username}`);

        $httpClient.post(request, (error, response, data) => {
            if (error) {
                const errMsg = `❌ 登录请求失败: ${error}`;
                log(errMsg);
                notify(errMsg);
                reject(new Error(`请求失败: ${error}`));
            } else {
                log(`✓ 收到登录响应: HTTP ${response.status}`);
                log(`📥 响应内容: ${data.substring(0, 200)}${data.length > 200 ? '...' : ''}`);
                
                try {
                    const result = JSON.parse(data);
                    log(`✓ 成功解析JSON响应`);
                    if (result.result === "success") {
                        const successMsg = "✅ 登录成功";
                        log(successMsg);
                        notify(successMsg);
                        resolve();
                    } else {
                        const errMsg = `❌ 登录失败: ${result.message || "服务端返回失败"}`;
                        log(errMsg);
                        notify(errMsg);
                        reject(new Error(result.message || "服务端返回失败"));
                    }
                } catch (e) {
                    log(`⚠️ JSON解析失败: ${e.message}，尝试文本匹配`);
                    if (data.includes('success')) {
                         const successMsg = "✅ 登录成功 (文本匹配)";
                         log(successMsg);
                         notify(successMsg);
                         resolve();
                    } else {
                        const errMsg = `❌ 响应解析失败，无法确认登录状态`;
                        log(errMsg);
                        notify(errMsg);
                        reject(new Error("响应解析失败"));
                    }
                }
            }
        });
    });
}

// 基础工具
function sleep(ms) {
    return new Promise(resolve => setTimeout(resolve, ms));
}
function parseArguments(argStr) {
    const args = {};
    if (!argStr) return args;
    argStr.split('&').forEach(pair => {
        const [key, value] = pair.split('=');
        if (key && value) {
            args[key.trim()] = value.trim().replace(/^["']|["']$/g, '');
        }
    });
    return args;
}

function getHeader(headers, key) {
    if (!headers) return null;
    const lower = key.toLowerCase();
    const found = Object.keys(headers).find(k => k.toLowerCase() === lower);
    return found ? headers[found] : null;
}

function parsePortalFromString(str) {
    if (!str) return null;
    const re = /(https?:\/\/[^\s'"<>]+?\/eportal\/index\.jsp\?[^'"<>]+)/i;
    const m = str.match(re);
    if (m && m[1]) return parsePortalUrl(m[1]);
    return null;
}

function parsePortalUrl(urlStr) {
    try {
        const u = new URL(urlStr);
        if (!u.pathname.includes('/eportal/index.jsp')) return null;
        const qs = u.search ? u.search.substring(1) : '';
        if (!qs) return null;
        return { baseUrl: `${u.protocol}//${u.host}`, queryString: qs };
    } catch (e) {
        log(`⚠️ 解析重定向失败: ${e.message}`);
        return null;
    }
}
