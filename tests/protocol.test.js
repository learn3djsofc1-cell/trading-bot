'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { parseSnapshotText, encodeField } = require('../src/protocol');

test('parses snapshot line protocol', () => {
  const body = [
    'SNAPSHOT|evt-1|MASTER_A|XAUUSDr|1710000000000',
    `POSITION|123|XAUUSDr|BUY|0.01|2350.12|2340|2360|0|${encodeField('manual')}|1710000000000`,
    `ORDER|456|XAUUSDr|BUY_LIMIT|0.02|2330|2320|2350|0|${encodeField('pending')}|0|1710000000001`,
    ''
  ].join('\n');

  const snapshot = parseSnapshotText(body);
  assert.equal(snapshot.eventId, 'evt-1');
  assert.equal(snapshot.positions.length, 1);
  assert.equal(snapshot.positions[0].comment, 'manual');
  assert.equal(snapshot.orders.length, 1);
  assert.equal(snapshot.orders[0].type, 'BUY_LIMIT');
});

test('rejects unsupported symbol row shape', () => {
  assert.throws(() => parseSnapshotText('SNAPSHOT|evt|MASTER_A|XAUUSDr|1\nBAD|x\n'), /unsupported snapshot row type/);
});
