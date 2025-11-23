/**
 * Surge Script: 校园网自动登录 (Ruijie ePortal)
 * 参考: https://www.cnblogs.com/0x000001/p/18766279
 * * 解决 macOS 下 Surge 未获取定位权限导致 SSID 为 null 的问题
 * * 逻辑变更: 仅在 SSID 存在且不匹配时退出；SSID 为空时尝试探测网络特征
 */

const CHECK_URL = 'http://www.baidu.com';
const USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36 Edg/134.0.0.0';

// 默认配置
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
    
    let delaySec = parseInt(args.delay);
    if (isNaN(delaySec)) delaySec = DEFAULT_CONFIG.delay;
    if (delaySec < 1) delaySec = 1;

    // --- 2. 环境预检 (智能宽松模式) ---
    const currentWifi = $network.wifi.ssid;
    
    // 核心修改逻辑：
    // 情况 A: 读到了 SSID，但名字不对 (例如在家里: "Home_WiFi") -> 退出
    if (currentWifi && currentWifi !== TARGET_SSID) {
        // console.log(`[CampusLogin] 当前 WiFi (${currentWifi}) 非目标网络，跳过。`);
        $done();
        return;
    }

    // 情况 B: 读到了正确的 SSID -> 继续
    // 情况 C: 读不到 SSID (null) -> 继续 (交给后续的 HTTP 探测来决定是否登录)
    
    const logSSID = currentWifi ? currentWifi : "未知(macOS/有线)";
    console.log(`[CampusLogin] 🎯 环境符合 (${logSSID})，等待网络就绪 (${delaySec}s)...`);
    
    await sleep(delaySec * 1000);

    try {
        // --- 3. 探测认证 ---
        const authInfo = await getAuthInfo();
        
        if (!authInfo) {
            // 只有在 SSID 明确匹配时才输出“无需登录”，否则在家里(null)会刷屏
            if (currentWifi === TARGET_SSID) {
                console.log("[CampusLogin] ✅ 无需认证，网络已连通。");
            }
            $done();
            return;
        }

        console.log(`[CampusLogin] 🔗 发现校园网认证页: ${authInfo.baseUrl}`);

        // --- 4. 执行登录 ---
        await login(args.username, args.password, authInfo);
        
    } catch (err) {
        console.log(`[CampusLogin] ❌ 异常: ${err.message}`);
        // 仅在脚本成功发起了登录请求却失败时弹窗，避免探测阶段的常规错误弹窗干扰
        if (err.message.includes("服务端") || err.message.includes("失败")) {
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
        $httpClient.get({ url: CHECK_URL, headers: { 'User-Agent': USER_AGENT } }, (error, response, data) => {
            if (error) {
                // 网络不通，不做处理直接结束
                resolve(null); 
                return;
            }

            // 1. 已经连通互联网
            if (response.status === 200 && data && data.includes('<title>百度一下，你就知道</title>')) {
                resolve(null);
                return;
            }
            
            // 2. 检测是否是锐捷 ePortal 重定向
            const regex = /href=['"]?(https?:\/\/.*?)\/eportal\/index\.jsp\?([^'"]+)['"]?/;
            const match = data.match(regex);

            if (match && match[1] && match[2]) {
                resolve({ baseUrl: match[1], queryString: match[2] });
            } else {
                // 既不是百度，也不是锐捷，可能是其他网络环境（如星巴克WiFi），忽略
                resolve(null);
            }
        });
    });
}

function login(username, password, authInfo) {
    return new Promise((resolve, reject) => {
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
            body: postBody
        };

        $httpClient.post(request, (error, response, data) => {
            if (error) {
                reject(new Error("登录请求网络失败"));
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