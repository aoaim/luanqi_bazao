/**
 * Surge Script: 校园网自动登录 (Ruijie ePortal)
 * 轻量版：检测重定向并使用双重编码登录
 */

const CHECK_URL_DOMAIN = 'http://www.baidu.com';
const CHECK_URL_IP = 'http://110.242.68.3';
const USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36 Edg/134.0.0.0';

const DEFAULT_CONFIG = {
    ssid: 'HebmuWlan',
    delay: 1,
    readyTimeout: 10
};

(async () => {
    const args = parseArguments($argument);
    if (!args.username || !args.password) {
        notify("❌ 请在模块参数填入账号密码");
        return $done();
    }

    const TARGET_SSID = args.ssid || DEFAULT_CONFIG.ssid;
    const delaySec = Math.max(parseInt(args.delay) || DEFAULT_CONFIG.delay, 0);
    const readyTimeout = Math.max(parseInt(args.readyTimeout) || DEFAULT_CONFIG.readyTimeout, 0);

    // 等待 IP 就绪（开机可能慢）
    let ssid = $network.wifi.ssid;
    let hasIP = Boolean($network && $network.v4 && $network.v4.primaryAddress);
    for (let i = 0; i < readyTimeout && !hasIP; i++) {
        await sleep(1000);
        ssid = $network.wifi.ssid;
        hasIP = Boolean($network && $network.v4 && $network.v4.primaryAddress);
        if (ssid && ssid !== TARGET_SSID) return $done();
    }
    if (ssid && ssid !== TARGET_SSID) return $done();

    if (delaySec > 0) await sleep(delaySec * 1000);

    // 探测 portal
    const info = await getAuthInfoHybrid();
    if (info.status === 'online') return $done();
    if (info.status !== 'portal') return $done();

    notify("🔗 检测到认证页面，开始登录");
    try {
        await login(args.username, args.password, info.data);
        notify("✅ 登录成功");
    } catch (e) {
        notify(`❌ 登录失败: ${e.message}`);
    }
    $done();
})();

// 探测认证
async function getAuthInfoHybrid() {
    const domains = [CHECK_URL_DOMAIN, CHECK_URL_IP];
    for (const url of domains) {
        try {
            const r = await detect(url);
            if (r) return { status: 'portal', data: r };
        } catch (e) {
            continue;
        }
    }
    return { status: 'online' };
}

function detect(url) {
    return new Promise((resolve, reject) => {
        $httpClient.get({
            url,
            headers: { 'User-Agent': USER_AGENT },
            timeout: 5
        }, (error, response, data) => {
            if (error) return reject(new Error(error));

            const loc = getHeader(response.headers, 'Location');
            if (loc) {
                const parsed = parsePortalUrl(loc);
                if (parsed) return resolve(parsed);
            }

            if (response.status === 200 && data && data.includes('百度一下')) {
                return resolve(null); // 已连网
            }

            const parsed = parsePortalFromString(data);
            return resolve(parsed || null);
        });
    });
}

function login(username, password, authInfo) {
    return new Promise((resolve, reject) => {
        const qsTwice = encodeURIComponent(encodeURIComponent(authInfo.queryString));
        const body = `userId=${username}&password=${password}&service=&queryString=${qsTwice}&operatorPwd=&operatorUserId=&validcode=&passwordEncrypt=false`;
        const loginUrl = `${authInfo.baseUrl}/eportal/InterFace.do?method=login`;

        $httpClient.post({
            url: loginUrl,
            headers: {
                "User-Agent": USER_AGENT,
                "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
                "Referer": `${authInfo.baseUrl}/eportal/index.jsp`,
                "Origin": authInfo.baseUrl
            },
            body,
            timeout: 15
        }, (error, response, data = '') => {
            if (error) return reject(new Error(error));
            try {
                const json = JSON.parse(data);
                if (json.result === "success") return resolve();
                return reject(new Error(json.message || "服务端返回失败"));
            } catch (e) {
                if (data.includes('success')) return resolve();
                return reject(new Error("响应解析失败"));
            }
        });
    });
}

// 工具
function sleep(ms) {
    return new Promise(r => setTimeout(r, ms));
}
function parseArguments(argStr) {
    const args = {};
    if (!argStr) return args;
    argStr.split('&').forEach(pair => {
        const [k, v] = pair.split('=');
        if (k && v) args[k.trim()] = v.trim().replace(/^["']|["']$/g, '');
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
        return null;
    }
}
