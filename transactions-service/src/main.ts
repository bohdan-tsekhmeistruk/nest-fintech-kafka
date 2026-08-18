import { NestFactory } from '@nestjs/core';
import { AppModule } from './app.module';
import { ZodValidationPipe } from './validation/zodValidation.pipeline';
import { WinstonModule } from 'nest-winston';
import winstonLogger from './winston.logger';
import { SwaggerModule, DocumentBuilder } from '@nestjs/swagger';

async function bootstrap() {
  const app = await NestFactory.create(AppModule);

  app.enableCors();
  app.useGlobalPipes(new ZodValidationPipe());
  app.useLogger(WinstonModule.createLogger(winstonLogger));

  app.setGlobalPrefix('api');

  const config = new DocumentBuilder()
    .setTitle('Transactions Service')
    .setDescription('Transactions Service API description')
    .setVersion('1.0')
    .build();
  const documentFactory = () => SwaggerModule.createDocument(app, config);
  SwaggerModule.setup('api', app, documentFactory);

  await app.listen(process.env.PORT ?? 3001);
}
bootstrap();
