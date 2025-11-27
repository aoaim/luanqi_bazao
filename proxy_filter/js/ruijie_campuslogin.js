/**
 * Surge Script: 校园网自动登录 (Ruijie ePortal)
 * 更新: 2025-11-27 16:32
 */

const USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36 Edg/134.0.0.0';
const CHECK_TARGETS = [
    { url: 'http://connect.rom.miui.com/generate_204', online: (res) => res.status === 204 },
    { url: 'http://www.baidu.com', online: (res, body) => res.status === 200 && body && body.includes('百度一下') },
    { url: 'http://110.242.68.3', online: () => false } // 兜底 IP
];

const DEFAULT_CONFIG = {
    ssid: 'HebmuWlan',
    delay: 1,              // 网络就绪后再等多少秒
    readyTimeout: 18,      // 等待 Wi-Fi + IP 的最长时间
    maxRetries: 4,         // 探测/登录重试
    retryInterval: 4       // 重试间隔
};

(async () => {
    log('========== Ruijie Auto Login ==========');
    const args = parseArguments($argument);
    const username = args.username;
    const password = args.password;

    if (!username || !password) {
        notify('❌ 请在模块参数中填写账号与密码');
        return $done();
    }

    const targetSsid = args.ssid || DEFAULT_CONFIG.ssid;
    const delaySec = clampToInt(args.delay, DEFAULT_CONFIG.delay, 0, 60);
    const readyTimeout = clampToInt(args.readyTimeout, DEFAULT_CONFIG.readyTimeout, 5, 60);
    const maxRetries = clampToInt(args.maxRetries, DEFAULT_CONFIG.maxRetries, 1, 10);
    const retryInterval = clampToInt(args.retryInterval, DEFAULT_CONFIG.retryInterval, 2, 30);

    log(`配置: SSID=${targetSsid}, readyTimeout=${readyTimeout}s, delay=${delaySec}s, retries=${maxRetries}/${retryInterval}s`);

    // 1) 等待 Wi-Fi 和 IP 就绪
    const readiness = await waitForNetworkReady(targetSsid, readyTimeout);
    if (readiness.status === 'skip') {
        log(`⏭️ 当前 Wi-Fi (${readiness.wifi || '未知'}) 非目标网络，退出`);
        return $done();
    }
    if (readiness.status === 'timeout') {
        notify(`⚠️ 等待网络就绪超时 (${readyTimeout}s)，未检测到 ${targetSsid}`);
        return $done();
    }

    if (delaySec > 0) {
        log(`⏳ 再等待 ${delaySec}s 让网络稳定`);
        await sleep(delaySec * 1000);
    }

    // 2) 探测是否需要认证
    let portal = null;
    let online = false;
    for (let i = 1; i <= maxRetries; i++) {
        log(`🔍 探测门户 (${i}/${maxRetries})`);
        const result = await detectPortal();
        if (result.status === 'portal') {
            portal = result.data;
            break;
        }
        if (result.status === 'online') {
            online = true;
            break;
        }
        if (i < maxRetries) {
            log(`⚠️ 未捕获认证页面，${retryInterval}s 后重试`);
            await sleep(retryInterval * 1000);
        }
    }

    if (online) {
        log('✅ 网络已连通，无需认证');
        return $done();
    }
    if (!portal) {
        notify('ℹ️ 未发现认证重定向，可能网络不可达');
        return $done();
    }

    notify('🔗 捕获到锐捷认证，开始登录...');

    // 3) 登录
    for (let i = 1; i <= maxRetries; i++) {
        try {
            await login(username, password, portal);
            notify('✅ 锐捷登录成功');
            return $done();
        } catch (e) {
            log(`⚠️ 登录失败(${i}/${maxRetries}): ${e.message}`);
            if (i < maxRetries) {
                await sleep(retryInterval * 1000);
            } else {
                notify(`❌ 登录失败: ${e.message}`);
            }
        }
    }
    $done();
})();

// ================= 核心逻辑 =================
function log(message) {
    const time = new Date().toLocaleTimeString();
    console.log(`[CampusLogin ${time}] ${message}`);
}

function notify(message) {
    $notification.post('校园网连接助手', '', message);
    log(message);
}

async function waitForNetworkReady(targetSsid, maxWaitSec) {
    for (let i = 0; i < maxWaitSec; i++) {
        const wifi = $network && $network.wifi ? $network.wifi.ssid : null;
        const hasIP = Boolean($network && $network.v4 && $network.v4.primaryAddress);

        if (wifi && targetSsid && wifi !== targetSsid) {
            return { status: 'skip', wifi };
        }
        if ((wifi || !targetSsid) && hasIP) {
            log(`✓ 网络接口已就绪: SSID=${wifi || '未知'}, IP=${$network.v4.primaryAddress}`);
            return { status: 'ready', wifi };
        }
        await sleep(1000);
    }
    return { status: 'timeout', wifi: $network && $network.wifi ? $network.wifi.ssid : null };
}

async function detectPortal() {
    for (const target of CHECK_TARGETS) {
        const res = await httpGet(target.url);
        if (!res) continue;

        const portal = extractPortal(res);
        if (portal) {
            log(`✓ 捕获认证页面: ${portal.baseUrl}`);
            return { status: 'portal', data: portal };
        }

        const isOnline = target.online && target.online(res.response, res.body);
        if (isOnline) {
            return { status: 'online' };
        }
    }
    return { status: 'error' };
}

function httpGet(url) {
    return new Promise((resolve) => {
        $httpClient.get(
            {
                url,
                headers: { 'User-Agent': USER_AGENT },
                timeout: 8
            },
            (error, response, body = '') => {
                if (error) {
                    log(`❌ 请求失败: ${error}`);
                    return resolve(null);
                }
                log(`📡 GET ${url} -> HTTP ${response.status}`);
                resolve({ response, body });
            }
        );
    });
}

function extractPortal(res) {
    const { response, body } = res;

    // 1) 302 Location
    const location = getHeader(response.headers, 'Location');
    if (location) {
        const parsed = parsePortalUrl(location);
        if (parsed) return parsed;
    }

    // 2) HTML 中的 eportal 链接
    const bodyMatch = body.match(/https?:\/\/[^"'\\s]+\/eportal\/index\.jsp\?[^"'<>\\s]+/i);
    if (bodyMatch) {
        const parsed = parsePortalUrl(bodyMatch[0]);
        if (parsed) return parsed;
    }

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
        log(`⚠️ 解析认证地址失败: ${e.message}`);
        return null;
    }
}

function login(username, password, authInfo) {
    return new Promise((resolve, reject) => {
        const qsEncoded = encodeURIComponent(encodeURIComponent(authInfo.queryString));
        const body = `userId=${username}&password=${password}&service=&queryString=${qsEncoded}&operatorPwd=&operatorUserId=&validcode=&passwordEncrypt=false`;
        const loginUrl = `${authInfo.baseUrl}/eportal/InterFace.do?method=login`;

        $httpClient.post(
            {
                url: loginUrl,
                headers: {
                    'User-Agent': USER_AGENT,
                    'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
                    Referer: `${authInfo.baseUrl}/eportal/index.jsp`,
                    Origin: authInfo.baseUrl
                },
                body,
                timeout: 12
            },
            (error, response, data = '') => {
                if (error) {
                    return reject(new Error(error));
                }
                log(`📡 POST ${loginUrl} -> HTTP ${response.status}`);
                log(`📥 响应片段: ${data.substring(0, 120)}${data.length > 120 ? '...' : ''}`);

                try {
                    const json = JSON.parse(data);
                    if (json.result === 'success') return resolve();
                    return reject(new Error(json.message || '服务端返回失败'));
                } catch (e) {
                    if (data.includes('success')) return resolve();
                    return reject(new Error('响应解析失败'));
                }
            }
        );
    });
}

// ================= 工具函数 =================
function sleep(ms) {
    return new Promise((r) => setTimeout(r, ms));
}

function clampToInt(value, fallback, min, max) {
    const n = parseInt(value, 10);
    if (Number.isNaN(n)) return fallback;
    return Math.min(Math.max(n, min), max);
}

function getHeader(headers, key) {
    if (!headers) return null;
    const lower = key.toLowerCase();
    const found = Object.keys(headers).find((k) => k.toLowerCase() === lower);
    return found ? headers[found] : null;
}

function parseArguments(argStr) {
    const args = {};
    if (!argStr) return args;
    argStr.split('&').forEach((pair) => {
        const [key, value] = pair.split('=');
        if (key && value !== undefined) {
            args[key.trim()] = value.trim().replace(/^["']|["']$/g, '');
        }
    });
    return args;
}
