import { z } from 'zod';

export const envSchema = z.object({
  NODE_ENV: z.literal(['development', 'production']).default('development'),
  PORT: z.coerce.number().optional(),
  DATABASE_URL: z.url(),
});

export type TEnv = z.infer<typeof envSchema>;
