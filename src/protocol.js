'use strict';

const POSITION_TYPES = new Set(['BUY', 'SELL']);
const PENDING_TYPES = new Set(['BUY_LIMIT', 'SELL_LIMIT', 'BUY_STOP', 'SELL_STOP', 'BUY_STOP_LIMIT', 'SELL_STOP_LIMIT']);

function parseSnapshotText(text) {
  if (typeof text !== 'string' || text.trim() === '') {
    throw new Error('snapshot body is empty');
  }

  const lines = text.replace(/\r\n/g, '\n').split('\n').map((line) => line.trim()).filter(Boolean);
  const header = lines.shift();
  if (!header) throw new Error('snapshot header is missing');

  const headerParts = header.split('|');
  if (headerParts[0] !== 'SNAPSHOT') throw new Error('first line must be SNAPSHOT');
  if (headerParts.length < 5) throw new Error('SNAPSHOT line must contain id, account, symbol, timestamp');

  const snapshot = {
    eventId: headerParts[1],
    account: headerParts[2],
    symbol: headerParts[3],
    timestamp: numberOrThrow(headerParts[4], 'timestamp'),
    positions: [],
    orders: [],
    raw: text.endsWith('\n') ? text : `${text}\n`
  };

  for (const line of lines) {
    const parts = line.split('|');
    if (parts[0] === 'POSITION') snapshot.positions.push(parsePosition(parts));
    else if (parts[0] === 'ORDER') snapshot.orders.push(parseOrder(parts));
    else throw new Error(`unsupported snapshot row type: ${parts[0]}`);
  }

  return snapshot;
}

function parsePosition(parts) {
  if (parts.length < 11) throw new Error('POSITION row must have 11 fields');
  const type = parts[3];
  if (!POSITION_TYPES.has(type)) throw new Error(`unsupported position type: ${type}`);
  return {
    ticket: parts[1],
    symbol: parts[2],
    type,
    volume: numberOrThrow(parts[4], 'position volume'),
    priceOpen: numberOrThrow(parts[5], 'position open price'),
    sl: numberOrThrow(parts[6], 'position sl'),
    tp: numberOrThrow(parts[7], 'position tp'),
    magic: parts[8],
    comment: decodeField(parts[9]),
    timeMsc: numberOrThrow(parts[10], 'position time')
  };
}

function parseOrder(parts) {
  if (parts.length < 12) throw new Error('ORDER row must have 12 fields');
  const type = parts[3];
  if (!PENDING_TYPES.has(type)) throw new Error(`unsupported order type: ${type}`);
  return {
    ticket: parts[1],
    symbol: parts[2],
    type,
    volume: numberOrThrow(parts[4], 'order volume'),
    priceOpen: numberOrThrow(parts[5], 'order open price'),
    sl: numberOrThrow(parts[6], 'order sl'),
    tp: numberOrThrow(parts[7], 'order tp'),
    magic: parts[8],
    comment: decodeField(parts[9]),
    expiration: numberOrThrow(parts[10], 'order expiration'),
    timeSetupMsc: numberOrThrow(parts[11], 'order setup time')
  };
}

function encodeField(value) {
  return Buffer.from(String(value ?? ''), 'utf8').toString('base64url');
}

function decodeField(value) {
  return Buffer.from(String(value ?? ''), 'base64url').toString('utf8');
}

function numberOrThrow(value, label) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) throw new Error(`${label} is not a finite number`);
  return parsed;
}

module.exports = {
  parseSnapshotText,
  encodeField,
  decodeField
};
