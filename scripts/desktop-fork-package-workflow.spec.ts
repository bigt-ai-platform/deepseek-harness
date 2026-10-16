import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import yaml from 'js-yaml'
import { expect, it } from 'vitest'

const root = resolve(import.meta.dirname, '..')
const workflow = yaml.load(readFileSync(resolve(root, '.github/workflows/desktop-fork-package.yml'), 'utf8')) as {
  on: Record<string, { inputs: Record<string, { description?: string; default?: string }> }>
  jobs: Record<string, {
    env?: Record<string, string>
    steps: Array<{ name?: string; uses?: string; run?: string; env?: Record<string, string> }>
  }>
}
const win = workflow.jobs['win-x64']!

it('writes the production policy settings a hosted win-x64 runner owns no other way', () => {
  const settings = win.steps.find(step => step.name === 'Write unsigned packaging settings')!
  expect(settings).toBeDefined()
  expect(settings.env).toEqual({ UPDATE_ORIGIN: '${{ inputs.update_origin }}' })
  expect(settings.run).toContain('IsNullOrWhiteSpace($env:UPDATE_ORIGIN)')
  expect(settings.run).toContain('DSH_DESKTOP_APP_ID=com.deepseek.harness')
  expect(settings.run).toContain('DSH_DESKTOP_AUTO_UPDATE_ENV=production')
  expect(settings.run).toContain('DSH_DESKTOP_MANDATORY_UPDATE_PROD_ORIGIN=')
  expect(settings.run).not.toContain('allowedAuthOrigins')
  expect(workflow.on.workflow_dispatch!.inputs.update_origin!.description).toContain('DSH_DESKTOP_MANDATORY_UPDATE_PROD_ORIGIN')
  // Ambient release settings never reach package-target.ts, so no policy may sit in job or step environments.
  expect(win.env).not.toHaveProperty('DSH_DESKTOP_MANDATORY_UPDATE_TEST_ORIGIN')
  expect(win.env).not.toHaveProperty('DSH_DESKTOP_MANDATORY_UPDATE_PROD_ORIGIN')
  for (const step of win.steps) expect(step.run ?? '').not.toContain('${{')
})

it('provides the settings before the installer build runs', () => {
  const build = win.steps.find(step => step.run?.includes('package:win:x64:unsigned'))!
  expect(build).toBeDefined()
  const settings = win.steps.findIndex(step => step.name === 'Write unsigned packaging settings')
  expect(settings).toBeGreaterThan(-1)
  expect(settings).toBeLessThan(win.steps.indexOf(build))
  expect(win.steps.some(step => step.run?.includes('apps/desktop/.env.windows'))).toBe(true)
})

it('builds an installer for every platform target by default', () => {
  expect(workflow.on.workflow_dispatch!.inputs.targets!.default).toBe('win-x64,mac-arm64,mac-x64,linux-x64')
  expect(Object.keys(workflow.jobs).sort()).toEqual(['linux-x64', 'mac-arm64', 'mac-x64', 'win-x64'])
  const packageScripts: Record<string, string> = {
    'mac-arm64': 'package:mac:arm64:unsigned',
    'mac-x64': 'package:mac:x64:unsigned',
    'linux-x64': 'package:linux:x64:unsigned',
  }
  for (const [target, script] of Object.entries(packageScripts)) {
    expect(workflow.jobs[target]!.steps.some(step => step.run?.includes(script))).toBe(true)
  }
})
