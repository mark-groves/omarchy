#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')
const vm = require('vm')
const src = fs.readFileSync(path.join(root, 'shell/services/PluginRegistry.qml'), 'utf8')

function extractFunction(name) {
  const start = src.indexOf(`function ${name}(`)
  if (start === -1) fail(`PluginRegistry.qml defines ${name}`)
  const brace = src.indexOf('{', start)
  let depth = 0
  for (let i = brace; i < src.length; i++) {
    if (src[i] === '{') depth++
    else if (src[i] === '}') {
      depth--
      if (depth === 0) return src.slice(start, i + 1)
    }
  }
  fail(`PluginRegistry.qml closes ${name}`)
}

const context = {
  Util: {
    isPlainObject(value) {
      return value !== null && typeof value === 'object' && !Array.isArray(value)
    }
  }
}
vm.createContext(context)
vm.runInContext(extractFunction('trustedCapabilities'), context)
vm.runInContext(extractFunction('stampHostCapabilities'), context)

const firstParty = {
  'omarchy.lock': {
    __isFirstParty: true,
    omarchy: { capabilities: ['authentication'] }
  },
  'omarchy.polkit': {
    __isFirstParty: true,
    omarchy: { capabilities: ['authentication'] }
  },
  'omarchy.idle': {
    __isFirstParty: true,
    omarchy: { capabilities: ['idle-config'] }
  },
  'omarchy.mixed': {
    __isFirstParty: true,
    omarchy: { capabilities: ['authentication', 'idle-config'] }
  }
}
const thirdParty = {
  'evil.lock': { omarchy: { clonedFrom: 'omarchy.lock' } },
  'evil.polkit': { omarchy: { clonedFrom: 'omarchy.polkit' } },
  'local.idle': { omarchy: { clonedFrom: 'omarchy.idle' } },
  'local.mixed': { omarchy: { clonedFrom: 'omarchy.mixed' } },
  'spoof': { omarchy: { capabilities: ['authentication'] } }
}

context.stampHostCapabilities(firstParty, thirdParty)

assertDeepEqual(
  firstParty['omarchy.lock'].__hostCapabilities,
  ['authentication'],
  'first-party lock keeps authentication'
)
assertDeepEqual(
  firstParty['omarchy.polkit'].__hostCapabilities,
  ['authentication'],
  'first-party polkit keeps authentication'
)
assertDeepEqual(
  thirdParty['evil.lock'].__hostCapabilities,
  [],
  'clonedFrom omarchy.lock does not grant authentication'
)
assertDeepEqual(
  thirdParty['evil.polkit'].__hostCapabilities,
  [],
  'clonedFrom omarchy.polkit does not grant authentication'
)
assertDeepEqual(
  firstParty['omarchy.idle'].__hostCapabilities,
  ['idle-config'],
  'first-party non-auth capabilities still stamp'
)
assertDeepEqual(
  thirdParty['local.idle'].__hostCapabilities,
  ['idle-config'],
  'clones still inherit non-auth host capabilities'
)
assertDeepEqual(
  thirdParty['local.mixed'].__hostCapabilities,
  ['idle-config'],
  'clones inherit mixed capabilities without authentication'
)
assertDeepEqual(
  thirdParty['spoof'].__hostCapabilities,
  [],
  'third-party manifests cannot self-grant host capabilities'
)
JS
