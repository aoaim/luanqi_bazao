/**
 * Surge Script: 校园网自动登录 (Ruijie ePortal)
 * 参考实现: https://www.cnblogs.com/0x000001/p/18766279
 * 功能:
 *  - 自动检测重定向并完成锐捷认证登录 (Ruijie ePortal)
 *  - 支持通过参数传入 `username` 和 `password`
 *  - 可配置 `ssid`（目标无线名）和 `delay`（等待网络就绪秒数）
 *  - 在无法读取 SSID（如 macOS）时仍会尝试探测并登录
 *  - 登录成功/失败使用通知提醒，并包含简单的错误处理与重试友好延时
 * 为 HebMUer 编写，已在 HebMU 测试通过: 2025-11-23
 * Made by Gemini 3.0 Pro
 * Update: 2025-11-23  17:56
 */

const CHECK_URL = 'http://www.baidu.com';
const USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36 Edg/134.0.0.0';

const DEFAULT_CONFIG = {
    ssid: 'HebmuWlan',
    delay: 2
};

(async () => {
    // --- 1. 参数解析 ---
    const args = parseArguments($argument);
    
    if (!args.username || !args.password) {
        $notification.post("校园网登录", "配置缺失", "请在模块设置中填写账号和密码");
        $done();
        return;
    }

    const TARGET_SSID = args.ssid || DEFAULT_CONFIG.ssid;
    let delaySec = parseInt(args.delay) || DEFAULT_CONFIG.delay;
    if (delaySec < 1) delaySec = 1;

    // --- 2. 环境预检 ---
    const currentWifi = $network.wifi.ssid;
    
    // 只有当明确读到 SSID 且不匹配时才退出
    // currentWifi 为 null (macOS 无权限) 时继续执行
    if (currentWifi && currentWifi !== TARGET_SSID) {
        $done();
        return;
    }

    const logSSID = currentWifi ? currentWifi : "未知(macOS/有线)";
    console.log(`[CampusLogin] 🎯 环境符合 (${logSSID})，等待网络 (${delaySec}s)...`);
    
    await sleep(delaySec * 1000);

    try {
        // --- 3. 探测认证 ---
        const authInfo = await getAuthInfo();
        
        if (!authInfo) {
            // 如果 SSID 匹配但没检测到重定向，说明可能已经连上了
            if (currentWifi === TARGET_SSID) console.log("[CampusLogin] ✅ 网络已连通或无需认证");
            $done();
            return;
        }

        console.log(`[CampusLogin] 🔗 捕获认证地址: ${authInfo.baseUrl}`);

        // --- 4. 执行登录 ---
        await login(args.username, args.password, authInfo);
        
    } catch (err) {
        console.log(`[CampusLogin] ❌ 异常: ${err.message}`);
        // 过滤掉常见的超时噪音
        if (!err.message.includes("timeout")) {
            $notification.post("校园网登录异常", "执行失败", err.message);
        }
        $done();
    }
})();

// ================= 工具函数 =================

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

function getAuthInfo() {
    return new Promise((resolve, reject) => {
        $httpClient.get({ 
            url: CHECK_URL, 
            headers: { 'User-Agent': USER_AGENT },
            timeout: 5 // 探测超时设置短一点
        }, (error, response, data) => {
            if (error) {
                // 网络不通 (DNS解析失败等)，直接返回 null，不抛错
                console.log(`[CampusLogin] 探测失败 (可能无网络): ${error}`);
                resolve(null);
                return;
            }

            // 1. 正常连通百度
            if (response.status === 200 && data && data.includes('<title>百度一下，你就知道</title>')) {
                resolve(null);
                return;
            }
            
            // 2. 锐捷重定向特征提取
            const regex = /href=['"]?(https?:\/\/.*?)\/eportal\/index\.jsp\?([^'"]+)['"]?/;
            const match = data.match(regex);

            if (match && match[1] && match[2]) {
                resolve({ baseUrl: match[1], queryString: match[2] });
            } else {
                resolve(null);
            }
        });
    });
}

function login(username, password, authInfo) {
    return new Promise((resolve, reject) => {
        // 双重编码逻辑
        const qsTwice = encodeURIComponent(encodeURIComponent(authInfo.queryString));
        const postBody = `userId=${username}&password=${password}&service=&queryString=${qsTwice}&operatorPwd=&operatorUserId=&validcode=&passwordEncrypt=false`;

        const request = {
            url: `${authInfo.baseUrl}/eportal/InterFace.do?method=login`,
            headers: {
                "User-Agent": USER_AGENT,
                "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
                "Referer": `${authInfo.baseUrl}/eportal/index.jsp`,
                "Origin": authInfo.baseUrl
            },
            body: postBody,
            timeout: 15 // 登录请求给长一点时间
        };

        $httpClient.post(request, (error, response, data) => {
            if (error) {
                reject(new Error(`请求失败: ${error}`));
            } else {
                try {
                    const result = JSON.parse(data);
                    if (result.result === "success") {
                        console.log("✅ [CampusLogin] 登录成功");
                        $notification.post("校园网登录成功", `账号: ${username}`, "验证通过");
                        resolve();
                    } else {
                        reject(new Error(result.message || "服务端返回失败"));
                    }
                } catch (e) {
                    if (data.includes('success')) {
                         console.log("✅ [CampusLogin] 登录成功 (Text Match)");
                         $notification.post("校园网登录成功", `账号: ${username}`, "验证通过");
                         resolve();
                    } else {
                        reject(new Error("响应解析失败"));
                    }
                }
            }
        });
    });
}