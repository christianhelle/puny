'use strict';

const value = process.env.INPUT_TEST_TOKEN || '';
console.log(`INPUT_TEST_TOKEN set: ${value.length > 0}`);
console.log(`INPUT_TEST_TOKEN length: ${value.length}`);
console.log(`INPUT_TEST_TOKEN prefix: ${value.length >= 4 ? value.slice(0, 4) : ''}`);

const allInputs = Object.keys(process.env)
  .filter((key) => key.startsWith('INPUT_'))
  .map((key) => `${key}=${(process.env[key] || '').length}`)
  .join(' | ');
console.log(`all INPUT_ env vars: ${allInputs}`);
