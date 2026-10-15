/** Carry workspace `link:` dependencies into the Desktop runtime closure. */

import { cpSync, globSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import * as yaml from 'js-yaml'

const REPOSITORY_ROOT = resolve(import.meta.dirname, '..', '..', '..')

/** One workspace package a selected manifest links to a directory outside the repository. */
export interface DesktopLinkedPackage {
  readonly name: string
  /** Absolute directory the declaring manifest's `link:` spec resolves to. */
  readonly source: string
}

/**
 * Index every workspace package name to its repository directory.
 * @param repositoryRoot - Repository whose workspace globs name the packages.
 * @returns Package name to repository-relative directory.
 */
function workspaceDirectories(repositoryRoot: string): Map<string, string> {
  const workspace = yaml.load(readFileSync(join(repositoryRoot, 'pnpm-workspace.yaml'), 'utf8')) as { packages: string[] }
  const directories = new Map<string, string>()
  for (const path of globSync(workspace.packages.map(pattern => `${pattern}/package.json`), { cwd: repositoryRoot })) {
    const manifest = JSON.parse(readFileSync(join(repositoryRoot, path), 'utf8')) as { name?: unknown }
    if (typeof manifest.name === 'string') directories.set(manifest.name, dirname(path))
  }
  return directories
}

/**
 * Collect the `link:` dependencies of the selected closure that point outside the repository.
 *
 * The release tarballs carry the link specs but not their targets, so a closure built only from
 * packed packages omits these runtime dependencies.
 * @param selectedNames - Package names the prepared package set contains.
 * @param repositoryRoot - Repository declaring the workspace and its link specs.
 * @returns Linked packages sorted by name, deduplicated.
 */
export function desktopLinkedPackages(
  selectedNames: readonly string[],
  repositoryRoot: string = REPOSITORY_ROOT,
): DesktopLinkedPackage[] {
  const directories = workspaceDirectories(repositoryRoot)
  const linked = new Map<string, string>()
  for (const name of selectedNames) {
    const directory = directories.get(name)
    if (directory === undefined) continue
    const manifest = JSON.parse(readFileSync(join(repositoryRoot, directory, 'package.json'), 'utf8')) as
      Record<string, Record<string, string> | undefined>
    for (const section of ['dependencies', 'peerDependencies', 'optionalDependencies']) {
      for (const [dependency, spec] of Object.entries(manifest[section] ?? {})) {
        if (!spec.startsWith('link:')) continue
        linked.set(dependency, resolve(repositoryRoot, directory, spec.slice('link:'.length)))
      }
    }
  }
  return [...linked.entries()].sort(([left], [right]) => left.localeCompare(right))
    .map(([name, source]) => ({ name, source }))
}

/**
 * Stage linked packages into a closure project and redirect every resolution to the staged copy.
 *
 * The dependency and the matching override make the production install resolve the link spec
 * declared by the packed packages to the staged directory instead of a missing path. The closure
 * also inherits the workspace's reviewed install-script decisions, because the linked package's
 * own dependencies come from the registry; an unlisted script still stops the install by name.
 * @param projectRoot - Disposable closure project holding the generated manifests.
 * @param linked - Linked packages to stage; an empty list changes nothing.
 * @param repositoryRoot - Repository whose reviewed install-script decisions the closure inherits.
 * @returns Nothing.
 */
export function stageLinkedPackages(
  projectRoot: string,
  linked: readonly DesktopLinkedPackage[],
  repositoryRoot: string = REPOSITORY_ROOT,
): void {
  if (linked.length === 0) return
  const staged = join(projectRoot, 'linked')
  mkdirSync(staged, { recursive: true })
  for (const entry of linked) {
    cpSync(entry.source, join(staged, entry.name), {
      recursive: true,
      filter: source => !/(?:^|[\\/])(?:node_modules|\.git)(?:[\\/]|$)/u.test(source),
    })
  }
  const manifestPath = join(projectRoot, 'package.json')
  const manifest = JSON.parse(readFileSync(manifestPath, 'utf8')) as { dependencies: Record<string, string> }
  const workspacePath = join(projectRoot, 'pnpm-workspace.yaml')
  const workspace = readFileSync(workspacePath, 'utf8')
  if (!workspace.includes('overrides:\n')) throw new Error('desktop runtime: closure workspace file has no overrides section')
  for (const entry of linked) manifest.dependencies[entry.name] = `file:./linked/${entry.name}`
  writeFileSync(manifestPath, `${JSON.stringify(manifest, undefined, 2)}\n`)
  const decisions = (yaml.load(readFileSync(join(repositoryRoot, 'pnpm-workspace.yaml'), 'utf8')) as {
    allowBuilds?: Record<string, boolean>
  }).allowBuilds ?? {}
  const target = yaml.load(workspace) as Record<string, unknown> & { allowBuilds?: Record<string, boolean> }
  writeFileSync(workspacePath, yaml.dump({
    ...target,
    allowBuilds: { ...decisions, ...target.allowBuilds },
  }).replace('overrides:\n',
    `overrides:\n${linked.map(entry => `  ${JSON.stringify(entry.name)}: file:./linked/${entry.name}\n`).join('')}`))
}
