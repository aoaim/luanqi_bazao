/**
 * Surge Script: 校园网自动登录 (Ruijie ePortal)
 * 参考: https://www.cnblogs.com/0x000001/p/18766279
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
    
    // 如果没有填写参数，打印错误日志并退出
    if (!args.username || !args.password) {
        console.log("❌ [CampusLogin] 错误: 未填写账号或密码，请检查模块设置");
        $notification.post("校园网登录", "配置缺失", "请在模块设置中填写账号和密码");
        $done();
        return;
    }

    const TARGET_SSID = args.ssid || DEFAULT_CONFIG.ssid;
    
    let delaySec = parseInt(args.delay);
    if (isNaN(delaySec)) delaySec = DEFAULT_CONFIG.delay;
    if (delaySec < 1) delaySec = 1;

    // --- 2. 环境预检 ---
    const currentWifi = $network.wifi.ssid;
    if (currentWifi !== TARGET_SSID) {
        // 非目标 WiFi，直接退出
        $done();
        return;
    }

    console.log(`[CampusLogin] 🎯 检测到 ${TARGET_SSID}，等待 DHCP (${delaySec}s)...`);
    await sleep(delaySec * 1000);

    try {
        // --- 3. 探测认证 ---
        const authInfo = await getAuthInfo();
        
        if (!authInfo) {
            console.log("[CampusLogin] ✅ 无需认证，网络已连通。");
            // $notification.post("校园网状态", "", "网络已连通");
            $done();
            return;
        }

        console.log(`[CampusLogin] 🔗 获取到认证地址: ${authInfo.baseUrl}`);

        // --- 4. 执行登录 ---
        await login(args.username, args.password, authInfo);
        
    } catch (err) {
        console.log(`[CampusLogin] ❌ 异常: ${err.message}`);
        $notification.post("校园网登录异常", "执行失败", err.message);
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
            // 去除首尾空格和可能存在的引号
            args[key.trim()] = value.trim().replace(/^["']|["']$/g, '');
        }
    });
    return args;
}

function getAuthInfo() {
    return new Promise((resolve, reject) => {
        $httpClient.get({ url: CHECK_URL, headers: { 'User-Agent': USER_AGENT } }, (error, response, data) => {
            if (error) {
                // 网络层面的错误，可能是 DHCP 还没分配好
                reject(new Error("无法连接检测地址 (Timeout/DNS Error)"));
                return;
            }

            // 如果已经连通 (返回百度标题)
            if (response.status === 200 && data && data.includes('<title>百度一下，你就知道</title>')) {
                resolve(null);
                return;
            }
            
            // 匹配日志中出现的: top.self.location.href='https://eportal.hebmu.edu.cn:8443/eportal/index.jsp?wlanuserip=...'
            const regex = /href=['"]?(https?:\/\/.*?)\/eportal\/index\.jsp\?([^'"]+)['"]?/;
            const match = data.match(regex);

            if (match && match[1] && match[2]) {
                resolve({ baseUrl: match[1], queryString: match[2] });
            } else {
                // 如果是其他未知响应
                console.log(`[CampusLogin] 未知响应内容片段: ${data.substring(0, 100)}`);
                reject(new Error("未找到锐捷认证特征码"));
            }
        });
    });
}

function login(username, password, authInfo) {
    return new Promise((resolve, reject) => {
        // 锐捷特定的双重编码
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
                // 处理响应
                try {
                    const result = JSON.parse(data);
                    if (result.result === "success") {
                        console.log("✅ [CampusLogin] 登录成功 (JSON)");
                        $notification.post("校园网登录成功", `账号: ${username}`, "验证通过");
                        resolve();
                    } else {
                        reject(new Error(result.message || "服务端返回 Fail"));
                    }
                } catch (e) {
                    // 降级处理：有些版本返回的不是 JSON
                    if (data.includes('success')) {
                         console.log("✅ [CampusLogin] 登录成功 (Text Match)");
                         $notification.post("校园网登录成功", `账号: ${username}`, "验证通过");
                         resolve();
                    } else {
                        reject(new Error("响应解析失败: 非 JSON 且无 success"));
                    }
                }
            }
        });
    });
}