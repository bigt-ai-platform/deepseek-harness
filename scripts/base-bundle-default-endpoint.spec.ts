import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { expect, it } from 'vitest'
import { Config, resolveAdapterOptions } from '@deepseek-ai/dsh-llm-deepseek-api-key'
import { createLaunchEnvironmentSnapshot } from '@deepseek-ai/dsh-launch-environment'
import { loadCordisYaml } from './cordis-yaml.ts'

const root = resolve(import.meta.dirname, '..')
const GATEWAY_BASE_URL = 'https://llm.bigt.ai/api'

interface PatchEntry { id?: string; name?: string; config?: Record<string, unknown> }

function bundleEntries(): PatchEntry[] {
  const patch = loadCordisYaml(
    readFileSync(resolve(root, 'packages/bundle/base/cordis.patch.yml'), 'utf8'),
  ) as Array<PatchEntry | { insert?: PatchEntry[] }>
  // The patch mixes top-level entries with `insert` blocks; flatten both.
  return patch.flatMap((entry) => ('insert' in entry && entry.insert ? entry.insert : [entry as PatchEntry]))
}

it('ships the fork gateway as the bundled DeepSeek endpoint', () => {
  const provider = bundleEntries().find(entry => entry.id === 'llm-deepseek')!
  expect(provider.name).toBe('@deepseek-ai/dsh-llm-deepseek-api-key')
  expect(provider.config?.baseURL).toBe(GATEWAY_BASE_URL)
  // The bundled endpoint is a plain value the settings section can replace, and
  // Config accepts it, so composition and settings agree on the field.
  expect(Config({ baseURL: GATEWAY_BASE_URL }).baseURL.get()).toBe(GATEWAY_BASE_URL)
})

it('keeps the settings value over the launch environment, and the environment over the public API', () => {
  const environment = createLaunchEnvironmentSnapshot([
    { source: 'process', values: { DEEPSEEK_BASE_URL: 'https://env.example/api' } },
  ])

  // A bundled or user-set endpoint outranks DEEPSEEK_BASE_URL, which is why the
  // guide tells public-API users to set the settings value instead.
  const configured = resolveAdapterOptions({ baseURL: GATEWAY_BASE_URL }, environment)
  expect(configured.baseURL).toBe(GATEWAY_BASE_URL)

  // Without a configured endpoint the launch environment still selects one.
  const fromEnvironment = resolveAdapterOptions({}, environment)
  expect(fromEnvironment.baseURL).toBe('https://env.example/api')
})
