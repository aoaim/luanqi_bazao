/**
 * Surge Script: 校园网自动登录 (Ruijie ePortal)
 * 参考: https://www.cnblogs.com/0x000001/p/18766279
 * * 功能: 自动识别 HTTPS/HTTP、域名/IP，支持自定义 SSID 和延时
 * * 参数 (在模块设置中填写):
 * - username: 学号
 * - password: 密码
 * - ssid: 目标 WiFi 名称 (例如 HebmuWlan)
 * - delay: 延时秒数 (1-10)
 */

const CHECK_URL = 'http://www.baidu.com';
const DEFAULT_SSID = 'HebmuWlan'; // 兜底默认值

(async () => {
    // --- 1. 参数处理 ---
    const args = parseArguments($argument);
    
    // 校验必填项
    if (!args.username || !args.password) {
        $notification.post("校园网登录", "配置错误", "请在模块设置中填写账号和密码");
        $done();
        return;
    }

    // 优先使用设置中的 SSID，如果没填则使用默认值
    const TARGET_SSID = args.ssid || DEFAULT_SSID;
    
    // 延时处理 (1-10秒)
    let delaySec = parseInt(args.delay);
    if (isNaN(delaySec)) delaySec = 3;
    if (delaySec < 1) delaySec = 1;
    if (delaySec > 10) delaySec = 10;

    // --- 2. 环境检查 ---
    const currentWifi = $network.wifi.ssid;
    
    // 只有在 SSID 匹配时才运行
    if (currentWifi !== TARGET_SSID) {
        // console.log(`当前 WiFi (${currentWifi}) 不匹配目标 (${TARGET_SSID})，脚本跳过。`);
        $done();
        return;
    }

    console.log(`检测到目标网络: ${TARGET_SSID}，等待 DHCP (${delaySec}s)...`);
    await sleep(delaySec * 1000);

    try {
        // --- 3. 探测认证地址 ---
        const authInfo = await getAuthInfo();
        
        if (!authInfo) {
            console.log("未检测到重定向，网络可能已连通。");
            $notification.post("校园网状态", "", `WiFi: ${TARGET_SSID}\n状态: 网络已连通`);
            $done();
            return;
        }

        console.log(`自动识别认证服务器: ${authInfo.baseUrl}`);

        // --- 4. 执行登录 ---
        await login(args.username, args.password, authInfo);
        
    } catch (err) {
        console.log(`❌ 执行出错: ${err}`);
        $notification.post("校园网登录异常", "错误", err.message);
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
        if (key && value) args[key.trim()] = value.trim();
    });
    return args;
}

function getAuthInfo() {
    return new Promise((resolve, reject) => {
        $httpClient.get({ url: CHECK_URL, headers: { 'User-Agent': 'curl/8.17.0' } }, (error, response, data) => {
            if (error) {
                reject(new Error("无法连接检测地址 (无IP或DNS失败)"));
                return;
            }

            if (response.status === 200 && data && data.includes('<title>百度一下，你就知道</title>')) {
                resolve(null);
                return;
            }
            
            // 正则提取 BaseURL 和 QueryString
            const regex = /href=['"]?(https?:\/\/.*?)\/eportal\/index\.jsp\?([^'"]+)['"]?/;
            const match = data.match(regex);

            if (match && match[1] && match[2]) {
                resolve({
                    baseUrl: match[1],
                    queryString: match[2]
                });
            } else {
                if (data.includes('location.href')) {
                    reject(new Error("检测到未知跳转格式"));
                } else {
                    reject(new Error("未检测到认证页特征"));
                }
            }
        });
    });
}

function login(username, password, authInfo) {
    return new Promise((resolve, reject) => {
        const qsOnce = encodeURIComponent(authInfo.queryString);
        const qsTwice = encodeURIComponent(qsOnce);

        const postBody = `userId=${username}&password=${password}&service=&queryString=${qsTwice}&operatorPwd=&operatorUserId=&validcode=&passwordEncrypt=false`;