const useColor = process.stdout.isTTY && !process.env.NO_COLOR;
const color = (code, value) => useColor ? `\x1b[${code}m${value}\x1b[0m` : value;

export const green = value => color('32', value);
export const yellow = value => color('33', value);
export const red = value => color('31', value);
export const dim = value => color('2', value);
export const bold = value => color('1', value);

export function summarizeChanges(counts) {
  const parts = [];
  if (counts.created) parts.push(green(`${counts.created} created`));
  if (counts.updated) parts.push(green(`${counts.updated} updated`));
  if (counts.identical) parts.push(dim(`${counts.identical} unchanged`));
  if (counts.conflicts) parts.push(yellow(`${counts.conflicts} conflict`));
  return parts.join(', ') || 'nothing to do';
}
