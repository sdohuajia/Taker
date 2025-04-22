import axios from 'axios';
import { ethers } from 'ethers';
import fs from 'fs';
import { HttpsProxyAgent } from 'https-proxy-agent';
import { SocksProxyAgent } from 'socks-proxy-agent';
import log from './utils/logger.js';
import ngopiBro from './utils/contract.js';

function readWallets() {
  if (fs.existsSync('wallets.json')) {
    const data = fs.readFileSync('wallets.json');
    return JSON.parse(data);
  } else {
    log.error('未找到 wallets.json 文件，程序退出...');
    process.exit(1);
  }
}

function readProxies() {
  if (fs.existsSync('proxy.txt')) {
    const data = fs.readFileSync('proxy.txt', 'utf8');
    const proxyList = data
      .split('\n')
      .map(line => line.trim())
      .filter(line => line.length > 0)
      .map(line => {
        const regexWithAuth = /^(http|socks5):\/\/([^:]+):([^@]+)@([^:]+):(\d+)$/;
        const regexWithoutAuth = /^(http|socks5):\/\/([^:]+):(\d+)$/;
        let match = line.match(regexWithAuth);
        if (match) {
          return {
            protocol: match[1],
            host: match[4],
            port: parseInt(match[5]),
            auth: {
              username: match[2],
              password: match[3],
            },
          };
        }
        match = line.match(regexWithoutAuth);
        if (match) {
          return {
            protocol: match[1],
            host: match[2],
            port: parseInt(match[3]),
          };
        }
        log.warn(`代理格式无效: ${line}`);
        return null;
      })
      .filter(proxy => proxy !== null);

    if (proxyList.length === 0) {
      log.error('proxy.txt 中未找到有效代理，程序退出...');
      process.exit(1);
    }
    return proxyList;
  } else {
    log.error('未找到 proxy.txt 文件，程序退出...');
    process.exit(1);
  }
}

const API = 'https://lightmining-api.taker.xyz/';
let currentProxyIndex = 0;
const proxies = readProxies();

function getNextProxy() {
  const proxy = proxies[currentProxyIndex];
  currentProxyIndex = (currentProxyIndex + 1) % proxies.length;
  return proxy;
}

function createAxiosInstance() {
  const proxy = getNextProxy();
  if (!proxy) {
    log.error('无法获取代理，跳过...');
    throw new Error('No valid proxy available');
  }

  let agent;
  if (proxy.protocol === 'http') {
    const proxyUrl = proxy.auth
      ? `http://${proxy.auth.username}:${proxy.auth.password}@${proxy.host}:${proxy.port}`
      : `http://${proxy.host}:${proxy.port}`;
    agent = new HttpsProxyAgent(proxyUrl);
  } else if (proxy.protocol === 'socks5') {
    const proxyOptions = {
      host: proxy.host,
      port: proxy.port,
      username: proxy.auth?.username,
      password: proxy.auth?.password,
    };
    agent = new SocksProxyAgent(proxyOptions);
  } else {
    log.error(`不支持的代理协议: ${proxy.protocol}`);
    throw new Error(`Unsupported proxy protocol: ${proxy.protocol}`);
  }

  return axios.create({
    baseURL: API,
    httpAgent: agent,
    httpsAgent: agent,
  });
}

const get = async (url, token, retries = 3) => {
  let lastError;
  for (let i = 0; i < retries; i++) {
    const proxy = proxies[currentProxyIndex === 0 ? proxies.length - 1 : currentProxyIndex - 1];
    try {
      const axiosInstance = createAxiosInstance();
      log.info(`使用代理: ${proxy.protocol}://${proxy.host}:${proxy.port}`);
      return await axiosInstance.get(url, {
        headers: {
          Authorization: `Bearer ${token}`,
        },
      });
    } catch (error) {
      lastError = error;
      log.error(`使用代理 ${proxy.protocol}://${proxy.host}:${proxy.port} 获取数据失败: ${error.message}`);
      if (i < retries - 1) {
        log.warn(`使用下一个代理重试... (剩余 ${retries - i - 1} 次)`);
        await sleep(3);
      } else {
        log.error('所有重试均失败。');
        throw lastError;
      }
    }
  }
};

const post = async (url, data, config = {}, retries = 3) => {
  let lastError;
  for (let i = 0; i < retries; i++) {
    const proxy = proxies[currentProxyIndex === 0 ? proxies.length - 1 : currentProxyIndex - 1];
    try {
      const axiosInstance = createAxiosInstance();
      log.info(`使用代理: ${proxy.protocol}://${proxy.host}:${proxy.port}`);
      return await axiosInstance.post(url, data, config);
    } catch (error) {
      lastError = error;
      log.error(`使用代理 ${proxy.protocol}://${proxy.host}:${proxy.port} 提交数据失败: ${error.message}`);
      if (i < retries - 1) {
        log.warn(`使用下一个代理重试... (剩余 ${retries - i - 1} 次)`);
        await sleep(3);
      } else {
        log.error('所有重试均失败。');
        throw lastError;
      }
    }
  }
};

const sleep = (s) => {
  return new Promise((resolve) => setTimeout(resolve, s * 1000));
};

async function signMessage(message, privateKey) {
  const wallet = new ethers.Wallet(privateKey);
  try {
    const signature = await wallet.signMessage(message);
    return signature;
  } catch (error) {
    log.error('签名消息失败:', error);
    return null;
  }
}

const getUser = async (token, retries = 3) => {
  try {
    const response = await get('user/getUserInfo', token);
    return response.data;
  } catch (error) {
    if (retries > 0) {
      log.error('获取用户信息失败:', error.message);
      log.warn(`重试... (剩余 ${retries - 1} 次)`);
      await sleep(3);
      return await getUser(token, retries - 1);
    } else {
      log.error('重试后仍无法获取用户信息:', error.message);
      return null;
    }
  }
};

const getNonce = async (walletAddress, retries = 3) => {
  try {
    const res = await post(`wallet/generateNonce`, { walletAddress });
    return res.data;
  } catch (error) {
    if (retries > 0) {
      log.error('获取随机数失败:', error.message);
      log.warn(`重试... (剩余 ${retries - 1} 次)`);
      await sleep(3);
      return await getNonce(walletAddress, retries - 1);
    } else {
      log.error('重试后仍无法获取随机数:', error.message);
      return null;
    }
  }
};

const login = async (address, message, signature, retries = 3) => {
  try {
    const res = await post(`wallet/login`, {
      address,
      invitationCode: '9M8HC',
      message,
      signature,
    });
    return res.data.data;
  } catch (error) {
    if (retries > 0) {
      log.error('登录失败:', error.message);
      log.warn(`重试... (剩余 ${retries - 1} 次)`);
      await sleep(3);
      return await login(address, message, signature, retries - 1);
    } else {
      log.error('重试后仍无法登录:', error.message);
      return null;
    }
  }
};

const getMinerStatus = async (token, retries = 3) => {
  try {
    const response = await get('assignment/totalMiningTime', token);
    return response.data;
  } catch (error) {
    if (retries > 0) {
      log.error('获取挖矿数据失败:', error.message);
      log.warn(`重试... (剩余 ${retries - 1} 次)`);
      await sleep(3);
      return await getMinerStatus(token, retries - 1);
    } else {
      log.error('重试后仍无法获取挖矿数据:', error.message);
      return null;
    }
  }
};

const startMine = async (token, retries = 3) => {
  try {
    const res = await post(
      `assignment/startMining`,
      {},
      { headers: { Authorization: `Bearer ${token}` } }
    );
    return res.data;
  } catch (error) {
    if (retries > 0) {
      log.error('开始挖矿失败:', error.message);
      log.warn(`重试... (剩余 ${retries - 1} 次)`);
      await sleep(3);
      return await startMine(token, retries - 1);
    } else {
      log.error('重试后仍无法开始挖矿:', error.message);
      return null;
    }
  }
};

const main = async () => {
  const wallets = readWallets();
  if (wallets.length === 0) {
    log.error('', 'wallets.json 文件中未找到钱包，程序退出。');
    process.exit(1);
  }
  if (proxies.length === 0) {
    log.error('', 'proxy.txt 文件中未找到有效代理，程序退出。');
    process.exit(1);
  }

  while (true) {
    log.warn('', ` === 服务器可能响应缓慢，耐心等待 ===`);
    log.info(`开始处理所有钱包:`, wallets.length);

    for (const wallet of wallets) {
      const nonceData = await getNonce(wallet.address);
      if (!nonceData || !nonceData.data || !nonceData.data.nonce) {
        log.error(`无法为钱包获取随机数: ${wallet.address}`);
        continue;
      }

      const nonce = nonceData.data.nonce;
      const signature = await signMessage(nonce, wallet.privateKey);
      if (!signature) {
        log.error(`无法为钱包签名消息: ${wallet.address}`);
        continue;
      }
      log.info(`尝试为钱包登录: ${wallet.address}`);
      const loginResponse = await login(wallet.address, nonce, signature);
      if (!loginResponse || !loginResponse.token) {
        log.error(`钱包登录失败: ${wallet.address}`);
        continue;
      } else {
        log.info(`登录成功...`);
      }

      log.info(`尝试检查用户信息...`);
      const userData = await getUser(loginResponse.token);
      if (userData && userData.data) {
        const { userId, twName, totalReward } = userData.data;
        log.info(`用户信息:`, { 用户ID: userId, Twitter名称: twName, 总奖励: totalReward });
        if (!twName) {
          log.error('', `此钱包 (${wallet.address}) 未绑定 Twitter/X，跳过...`);
          continue;
        }
      } else {
        log.error(`无法获取钱包用户信息: ${wallet.address}`);
      }

      log.info('尝试检查用户挖矿状态...');
      const minerStatus = await getMinerStatus(loginResponse.token);
      if (minerStatus && minerStatus.data) {
        const lastMiningTime = minerStatus.data?.lastMiningTime || 0;
        const nextMiningTime = lastMiningTime + 24 * 60 * 60;
        const nextDate = new Date(nextMiningTime * 1000);
        const dateNow = new Date();

        log.info(`上次挖矿时间:`, new Date(lastMiningTime * 1000).toLocaleString());
        if (dateNow > nextDate) {
          log.info(`尝试为钱包开始挖矿: ${wallet.address}`);
          const mineResponse = await startMine(loginResponse.token);
          log.info('挖矿响应:', mineResponse);
          if (mineResponse) {
            log.info(`尝试为钱包激活链上挖矿: ${wallet.address}`);
            const isMiningSuccess = await ngopiBro(wallet.privateKey);
            if (!isMiningSuccess) {
              log.error(`钱包今日已开始挖矿或无 Taker 余额`);
            }
          } else {
            log.error(`无法为钱包开始挖矿: ${wallet.address}`);
          }
        } else {
          log.warn(`挖矿已开始，下次挖矿时间为:`, nextDate.toLocaleString());
        }
      }
    }

    log.info('所有钱包处理完成，冷却 1 小时后再次检查...');
    await sleep(60 * 60);
  }
};

main();
