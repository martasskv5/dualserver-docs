import React from 'react'
import clsx from 'clsx'

/**
 * FirewallRulesTable - A styled table component for firewall rule documentation
 * 
 * Usage in MDX:
 * 
 * import { FirewallRulesTable } from "@/components/mdx"
 * 
 * <FirewallRulesTable
 *   rules={[
 *     { action: 'Pass', protocol: 'TCP', source: 'MGMT', destination: '172.27.15.10', port: '8006', description: 'Proxmox API' },
 *     { action: 'Pass', protocol: 'TCP', source: 'MGMT', destination: '172.27.15.10', port: '22', description: 'SSH for pct_remote' },
 *     { action: 'Pass', protocol: 'TCP', source: 'MGMT', destination: '172.27.15.0/24', port: 'Any', description: '(Optional) Full LAN access' },
 *     { action: 'Pass', protocol: '*', source: 'MGMT', destination: '*', port: '*', description: 'Default LAN→WAN (if not already present)' },
 *   ]}
 * />
 * 
 * Or with custom columns:
 * 
 * <FirewallRulesTable
 *   columns={['Action', 'Protocol', 'Source', 'Destination', 'Port', 'Description']}
 *   rules={[
 *     ['Pass', 'TCP', 'MGMT', '172.27.15.10', '8006', 'Proxmox API'],
 *     ['Pass', 'TCP', 'MGMT', '172.27.15.10', '22', 'SSH for pct_remote'],
 *   ]}
 * />
 */

const actionStyles = {
  Pass: 'bg-emerald-500/10 text-emerald-700 dark:bg-emerald-500/20 dark:text-emerald-300 border-emerald-500/20',
  Deny: 'bg-red-500/10 text-red-700 dark:bg-red-500/20 dark:text-red-300 border-red-500/20',
  Drop: 'bg-red-500/10 text-red-700 dark:bg-red-500/20 dark:text-red-300 border-red-500/20',
  Reject: 'bg-orange-500/10 text-orange-700 dark:bg-orange-500/20 dark:text-orange-300 border-orange-500/20',
  Allow: 'bg-emerald-500/10 text-emerald-700 dark:bg-emerald-500/20 dark:text-emerald-300 border-emerald-500/20',
  Block: 'bg-red-500/10 text-red-700 dark:bg-red-500/20 dark:text-red-300 border-red-500/20',
}

const protocolStyles = {
  TCP: 'text-sky-700 dark:text-sky-300',
  UDP: 'text-violet-700 dark:text-violet-300',
  ICMP: 'text-amber-700 dark:text-amber-300',
  '*': 'text-zinc-500 dark:text-zinc-400 italic',
  Any: 'text-zinc-500 dark:text-zinc-400 italic',
}

function ActionBadge({ action }) {
  const style = actionStyles[action] || actionStyles.Pass
  return (
    <span
      className={clsx(
        'inline-flex items-center rounded-full border px-2.5 py-0.5 text-xs font-semibold uppercase tracking-wide',
        style
      )}
    >
      {action}
    </span>
  )
}

function ProtocolBadge({ protocol }) {
  const style = protocolStyles[protocol] || protocolStyles['*']
  return (
    <span className={clsx('text-sm font-mono font-medium', style)}>
      {protocol}
    </span>
  )
}

function WildcardValue({ value }) {
  const isWildcard = value === '*' || value === 'Any' || value === 'any'
  return (
    <span
      className={clsx(
        'text-sm',
        isWildcard
          ? 'italic text-zinc-400 dark:text-zinc-500'
          : 'text-zinc-700 dark:text-zinc-300'
      )}
    >
      {value}
    </span>
  )
}

function PortValue({ port }) {
  const isWildcard = port === '*' || port === 'Any' || port === 'any'
  const isRange = port && (port.includes('-') || port.includes(':'))
  return (
    <span
      className={clsx(
        'text-sm font-mono',
        isWildcard
          ? 'italic text-zinc-400 dark:text-zinc-500'
          : isRange
            ? 'text-amber-600 dark:text-amber-400'
            : 'text-zinc-700 dark:text-zinc-300'
      )}
    >
      {port}
    </span>
  )
}

function IPValue({ value }) {
  const isWildcard = value === '*' || value === 'Any' || value === 'any'
  const isCIDR = value && value.includes('/')
  return (
    <span
      className={clsx(
        'text-sm font-mono',
        isWildcard
          ? 'italic text-zinc-400 dark:text-zinc-500'
          : isCIDR
            ? 'text-sky-600 dark:text-sky-400'
            : 'text-zinc-700 dark:text-zinc-300'
      )}
    >
      {value}
    </span>
  )
}

export function FirewallRulesTable({
  rules = [],
  columns = ['Action', 'Protocol', 'Source', 'Destination', 'Port', 'Description'],
  caption,
  className,
}) {
  // Detect if rules are objects or arrays
  const isObjectRules = rules.length > 0 && typeof rules[0] === 'object' && !Array.isArray(rules[0])

  // Normalize rules to array format
  const normalizedRules = isObjectRules
    ? rules.map((r) => [
        r.action || r.Action || '-',
        r.protocol || r.Protocol || '-',
        r.source || r.Source || '-',
        r.destination || r.Destination || '-',
        r.port || r.Port || '-',
        r.description || r.Description || '-',
      ])
    : rules

  return (
    <div className={clsx('my-6 overflow-x-auto rounded-xl border border-zinc-200 dark:border-zinc-800', className)}>
      <table className="w-full text-left text-sm">
        {caption && (
          <caption className="border-b border-zinc-200 bg-zinc-50 px-4 py-3 text-left text-xs font-semibold uppercase tracking-wider text-zinc-500 dark:border-zinc-800 dark:bg-zinc-900/50 dark:text-zinc-400">
            {caption}
          </caption>
        )}
        <thead>
          <tr className="border-b border-zinc-200 bg-zinc-50 dark:border-zinc-800 dark:bg-zinc-900/50">
            {columns.map((col, i) => (
              <th
                key={i}
                className="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wider text-zinc-500 dark:text-zinc-400"
              >
                {col}
              </th>
            ))}
          </tr>
        </thead>
        <tbody className="divide-y divide-zinc-100 dark:divide-zinc-800/50">
          {normalizedRules.map((rule, rowIdx) => (
            <tr
              key={rowIdx}
              className="transition-colors hover:bg-zinc-50/50 dark:hover:bg-zinc-800/30"
            >
              {rule.map((cell, cellIdx) => {
                const colName = columns[cellIdx]
                return (
                  <td key={cellIdx} className="px-4 py-3">
                    {colName === 'Action' || colName === 'action' ? (
                      <ActionBadge action={cell} />
                    ) : colName === 'Protocol' || colName === 'protocol' ? (
                      <ProtocolBadge protocol={cell} />
                    ) : colName === 'Port' || colName === 'port' ? (
                      <PortValue port={cell} />
                    ) : colName === 'Source' || colName === 'source' || colName === 'Destination' || colName === 'destination' ? (
                      <IPValue value={cell} />
                    ) : (
                      <span className="text-zinc-700 dark:text-zinc-300">{cell}</span>
                    )}
                  </td>
                )
              })}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

/**
 * SimpleFirewallTable - Even simpler variant for quick use
 * Just pass rows as arrays, auto-detects action/protocol styling
 * 
 * <SimpleFirewallTable>
 *   | Pass | TCP | MGMT | 172.27.15.10 | 8006 | Proxmox API |
 *   | Pass | TCP | MGMT | 172.27.15.10 | 22 | SSH for pct_remote |
 * </SimpleFirewallTable>
 * 
 * Or with data prop:
 * <SimpleFirewallTable data={[['Pass','TCP','MGMT','172.27.15.10','8006','Proxmox API']]} />
 */
export function SimpleFirewallTable({ data = [], children, caption }) {
  // If children is provided, parse pipe-delimited text
  let parsedData = data
  if (children && typeof children === 'string') {
    parsedData = children
      .trim()
      .split('\n')
      .map((line) =>
        line
          .split('|')
          .map((cell) => cell.trim())
          .filter((cell) => cell !== '')
      )
      .filter((row) => row.length > 0)
  }

  return (
    <FirewallRulesTable
      rules={parsedData}
      caption={caption}
    />
  )
}