import { PipeTransform, BadRequestException } from '@nestjs/common';
import { z, ZodError } from 'zod';
import { envSchema } from './dto/env.dto';

export class ZodValidationPipe implements PipeTransform {
  transform(value: unknown) {
    try {
      const parsedValue = envSchema.parse(value);
      return parsedValue;
    } catch (error: unknown) {
      if (error instanceof ZodError) {
        throw new BadRequestException(z.treeifyError(error));
      }
      throw new BadRequestException('Invalid request');
    }
  }
}
