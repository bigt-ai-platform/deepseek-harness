/** Linked workspace dependencies must reach the Desktop runtime closure. */

import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { desktopLinkedPackages, stageLinkedPackages } from '../scripts/linked-runtime-packages.ts'

const roots: string[] = []

afterEach(async () => {
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })))
})

/** One repository whose connection package links a package beside it, plus a closure project. */
function fixture(): { repository: string; linkedSource: string; project: string } {
  const root = mkdtempSync(join(tmpdir(), 'dsh-linked-'))
  roots.push(root)
  const repository = join(root, 'repository')
  const linkedSource = join(root, 'sibling', 'bigtangle-ts')
  const project = join(root, 'project')
  mkdirSync(join(repository, 'packages', 'client', 'connection'), { recursive: true })
  mkdirSync(join(linkedSource, 'dist'), { recursive: true })
  mkdirSync(join(linkedSource, 'node_modules', 'hoisted'), { recursive: true })
  mkdirSync(project, { recursive: true })
  writeFileSync(join(repository, 'pnpm-workspace.yaml'),
    'packages:\n  - packages/*/*\n\nallowBuilds:\n  secp256k1: false\n  node-pty: true\n')
  writeFileSync(join(repository, 'packages', 'client', 'connection', 'package.json'), `${JSON.stringify({
    name: '@deepseek-ai/dsh-client-connection',
    dependencies: { 'bigtangle-ts': 'link:../../../../sibling/bigtangle-ts' },
    peerDependencies: { '@deepseek-ai/cordis': 'workspace:~' },
  }, undefined, 2)}\n`)
  writeFileSync(join(linkedSource, 'package.json'), `${JSON.stringify({ name: 'bigtangle-ts', version: '1.0.9' }, undefined, 2)}\n`)
  writeFileSync(join(linkedSource, 'dist', 'index.js'), 'export const marker = true\n')
  writeFileSync(join(project, 'package.json'), `${JSON.stringify({
    name: '@deepseek-ai/dsh-desktop-runtime', private: true, version: '0.0.0',
    dependencies: { '@deepseek-ai/dsh': 'file:./desktop-packages/dsh.tgz' },
  }, undefined, 2)}\n`)
  writeFileSync(join(project, 'pnpm-workspace.yaml'),
    "packages:\n  - .\n\noverrides:\n  '@deepseek-ai/dsh': file:./desktop-packages/dsh.tgz\n\nnodeLinker: hoisted\nautoInstallPeers: false\nallowBuilds:\n  koffi: true\n")
  return { repository, linkedSource, project }
}

describe('linked runtime packages', () => {
  it('collects the link targets of selected packages and ignores everything else', () => {
    const { repository, linkedSource } = fixture()
    expect(desktopLinkedPackages(['@deepseek-ai/dsh-client-connection'], repository))
      .toEqual([{ name: 'bigtangle-ts', source: resolve(linkedSource) }])
    expect(desktopLinkedPackages(['@deepseek-ai/dsh-client-connection', 'not-a-workspace-package'], repository))
      .toHaveLength(1)
    expect(desktopLinkedPackages(['not-a-workspace-package'], repository)).toEqual([])
  })

  it('stages the linked package, its dependency, its override and the workspace build decisions', () => {
    const { repository, linkedSource, project } = fixture()
    stageLinkedPackages(project, desktopLinkedPackages(['@deepseek-ai/dsh-client-connection'], repository), repository)

    const staged = join(project, 'linked', 'bigtangle-ts')
    expect(readFileSync(join(staged, 'dist', 'index.js'), 'utf8')).toContain('marker')
    expect(() => readFileSync(join(staged, 'node_modules', 'hoisted', 'x'), 'utf8')).toThrow()
    const manifest = JSON.parse(readFileSync(join(project, 'package.json'), 'utf8')) as { dependencies: Record<string, string> }
    expect(manifest.dependencies['bigtangle-ts']).toBe('file:./linked/bigtangle-ts')
    const workspace = readFileSync(join(project, 'pnpm-workspace.yaml'), 'utf8')
    expect(workspace).toContain('"bigtangle-ts": file:./linked/bigtangle-ts')
    expect(workspace).toContain('secp256k1: false')
    expect(workspace).toContain('koffi: true')
    expect(dirname(join(staged, 'package.json'))).toBe(staged)
    expect(linkedSource).toContain('sibling')
  })

  it('changes nothing when no package is linked', () => {
    const { project } = fixture()
    const before = readFileSync(join(project, 'package.json'), 'utf8')
    stageLinkedPackages(project, [])
    expect(readFileSync(join(project, 'package.json'), 'utf8')).toBe(before)
  })

  it('refuses a closure workspace file without an overrides section', () => {
    const { repository, project } = fixture()
    writeFileSync(join(project, 'pnpm-workspace.yaml'), 'packages:\n  - .\n')
    expect(() => {
      stageLinkedPackages(project, desktopLinkedPackages(['@deepseek-ai/dsh-client-connection'], repository), repository)
    }).toThrow(/overrides section/u)
  })
})
