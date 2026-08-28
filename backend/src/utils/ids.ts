import { randomUUID } from 'crypto';

export function newId(prefix: string): string {
  return `${prefix}_${randomUUID()}`;
}

export function newUuid(): string {
  return randomUUID();
}
