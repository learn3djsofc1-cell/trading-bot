'use strict';

const fs = require('node:fs');
const path = require('node:path');

function loadConfig() {
  const configPath = process.env.COPIER_CONFIG || path.join(process.cwd(), 'config', 'default.json');
  const parsed = JSON.parse(fs.readFileSync(configPath, 'utf8'));

  const config = {
    ...parsed,
    host: process.env.COPIER_HOST || parsed.host || '127.0.0.1',
    port: Number(process.env.COPIER_PORT || parsed.port || 8787),
    authToken: process.env.COPIER_TOKEN || parsed.authToken,
    symbol: process.env.COPIER_SYMBOL || parsed.symbol || 'XAUUSDr'
  };

  if (!config.authToken || config.authToken === 'CHANGE_ME_LONG_RANDOM_TOKEN') {
    throw new Error('Set a strong authToken in config/default.json or COPIER_TOKEN before starting the relay.');
  }
  if (!Number.isInteger(config.port) || config.port < 1 || config.port > 65535) {
    throw new Error('config.port must be a valid TCP port.');
  }
  return config;
}

module.exports = { loadConfig };
